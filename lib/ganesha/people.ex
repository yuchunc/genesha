defmodule Ganesha.People do
  @moduledoc "Students and the names they are known by."

  import Ecto.Query, warn: false
  alias Ganesha.People.{LineMember, Student, StudentAlias}
  alias Ganesha.Repo

  def list_students do
    Repo.all(from s in Student, order_by: [desc: s.active, asc: s.display_name])
  end

  def list_active_students do
    Repo.all(from s in Student, where: s.active, order_by: s.display_name)
  end

  def get_student!(id), do: Student |> Repo.get!(id) |> Repo.preload(:aliases)

  def get_student(id), do: Repo.get(Student, id)

  def create_student(attrs) do
    %Student{} |> Student.changeset(attrs) |> Repo.insert()
  end

  def update_student(%Student{} = student, attrs) do
    student |> Student.changeset(attrs) |> Repo.update()
  end

  def change_student(%Student{} = student, attrs \\ %{}) do
    Student.changeset(student, attrs)
  end

  @doc "Adds a LINE ingestion alias for resolving free-text student names."
  def add_alias(%Student{} = student, alias_text) do
    %StudentAlias{}
    |> StudentAlias.changeset(%{student_id: student.id, alias: alias_text})
    |> Repo.insert()
  end

  @doc "Finds a student from a LINE ingestion alias."
  def find_by_alias(nil), do: nil

  def find_by_alias(alias_text) do
    Repo.one(
      from s in Student,
        join: a in StudentAlias,
        on: a.student_id == s.id,
        where: a.alias == ^alias_text
    )
  end

  @doc "Finds a student by LINE user id during LINE ingestion."
  def find_by_line_user_id(nil), do: nil

  def find_by_line_user_id(line_user_id) do
    Repo.get_by(Student, line_user_id: line_user_id)
  end

  @doc """
  Links a LINE user id to a student who has none (spec 2026-10-07 §2).
  Already linked to that id is a no-op. Fails with `:line_user_id_taken`
  when another student holds it, or `:student_line_user_id_changed` when
  this student is linked to a different one.
  """
  def link_line_user_id(%Student{line_user_id: line_user_id} = student, line_user_id)
      when is_binary(line_user_id),
      do: {:ok, student}

  def link_line_user_id(%Student{line_user_id: nil} = student, line_user_id)
      when is_binary(line_user_id) do
    case find_by_line_user_id(line_user_id) do
      nil -> update_student(student, %{line_user_id: line_user_id})
      %Student{} -> {:error, :line_user_id_taken}
    end
  end

  def link_line_user_id(%Student{}, line_user_id) when is_binary(line_user_id),
    do: {:error, :student_line_user_id_changed}

  # --- LINE group members (spec 2026-10-19-november-launch-design.md §1) ---

  @type resolution ::
          {:known, Student.t()}
          | :not_student
          | :pending
          | {:created, Student.t()}
          | {:linked, Student.t()}
          | {:unsure, [Student.t()]}

  def get_line_member(line_user_id), do: Repo.get_by(LineMember, line_user_id: line_user_id)

  @doc """
  Every Student, active or not, whose display name or an alias equals
  `display_name` after normalization, ordered by id.
  """
  def matching_students(display_name) do
    name = normalize_name(display_name)

    from(s in Student, order_by: s.id, preload: :aliases)
    |> Repo.all()
    |> Enum.filter(fn student ->
      Enum.any?(
        [student.display_name | Enum.map(student.aliases, & &1.alias)],
        &(normalize_name(&1) == name)
      )
    end)
  end

  @doc """
  Resolves a LINE group member to a Student by LINE id, then by name:

    1. a Student has this LINE id: `{:known, student}`
    2. the teacher said not a student: `:not_student`
    3. an open question exists: `:pending`
    4. no Student matches the name: `{:created, student}`
    5. one active, unlinked match: `{:linked, student}`
    6. anything else: `{:unsure, candidates}`, recorded as an `unsure` member

  Cases 4-6 run in one transaction. If a concurrent event for the same member
  wins the race on `line_user_id`, its outcome is re-read and returned. If the
  one matching Student is claimed by another LINE id meanwhile, the name is
  matched again and lands in case 6.
  """
  @spec resolve_line_member(String.t(), String.t()) :: resolution()
  def resolve_line_member(line_user_id, display_name)
      when is_binary(line_user_id) and is_binary(display_name) do
    lookup_line_member(line_user_id) || resolve_by_name(line_user_id, String.trim(display_name))
  end

  # Cases 1-3, or nil when the member has never been resolved.
  defp lookup_line_member(line_user_id) do
    case find_by_line_user_id(line_user_id) do
      %Student{} = student ->
        {:known, student}

      nil ->
        case get_line_member(line_user_id) do
          %LineMember{state: "not_student"} -> :not_student
          %LineMember{state: "unsure"} -> :pending
          nil -> nil
        end
    end
  end

  # Cases 4-6.
  defp resolve_by_name(line_user_id, name) do
    result =
      Repo.transaction(fn ->
        case apply_name_match(line_user_id, name, matching_students(name)) do
          {:ok, resolution} -> resolution
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, resolution} -> resolution
      {:error, reason} -> resolve_lost_race(line_user_id, name, reason)
    end
  end

  # A concurrent event got there first. If it resolved this member, its outcome
  # stands; if it claimed the matched Student for another member, match again.
  defp resolve_lost_race(line_user_id, name, reason) do
    resolution = if lost_race?(reason), do: lookup_line_member(line_user_id)

    cond do
      resolution -> resolution
      reason == :already_linked -> resolve_by_name(line_user_id, name)
      true -> raise "could not resolve LINE member #{line_user_id}: #{inspect(reason)}"
    end
  end

  defp apply_name_match(line_user_id, name, []) do
    %{display_name: name, line_user_id: line_user_id}
    |> create_student()
    |> tag(:created)
  end

  defp apply_name_match(line_user_id, _name, [%Student{active: true, line_user_id: nil} = student]) do
    student |> claim_unlinked_student(line_user_id) |> tag(:linked)
  end

  defp apply_name_match(line_user_id, name, candidates) do
    %LineMember{}
    |> LineMember.changeset(%{line_user_id: line_user_id, display_name: name, state: "unsure"})
    |> Repo.insert()
    |> case do
      {:ok, _member} -> {:ok, {:unsure, candidates}}
      error -> error
    end
  end

  defp tag({:ok, student}, outcome), do: {:ok, {outcome, student}}
  defp tag({:error, reason}, _outcome), do: {:error, reason}

  defp lost_race?(reason) when reason in [:already_linked, :line_user_id_taken], do: true

  defp lost_race?(%Ecto.Changeset{errors: errors}) do
    case errors[:line_user_id] do
      {_message, opts} -> opts[:constraint] == :unique
      nil -> false
    end
  end

  defp lost_race?(_reason), do: false

  @doc """
  Links `line_user_id` to `student` only while the stored row is still
  unlinked (compare-and-set), so a stale struct cannot overwrite a link made
  meanwhile. `{:error, :already_linked}` when it was, `{:error,
  :line_user_id_taken}` when another Student holds `line_user_id`.
  """
  def claim_unlinked_student(%Student{id: id}, line_user_id) when is_binary(line_user_id) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second)

    from(s in Student, where: s.id == ^id and is_nil(s.line_user_id), select: s)
    |> Repo.update_all(set: [line_user_id: line_user_id, updated_at: stamp])
    |> case do
      {1, [student]} -> {:ok, student}
      {0, []} -> {:error, :already_linked}
    end
  rescue
    error in Exqlite.Error ->
      case Ecto.Adapters.SQLite3.Connection.to_constraints(error, []) do
        [unique: "students_line_user_id_index"] -> {:error, :line_user_id_taken}
        _other -> reraise error, __STACKTRACE__
      end
  end

  defp normalize_name(name),
    do: name |> String.normalize(:nfkc) |> String.trim() |> String.downcase()
end
