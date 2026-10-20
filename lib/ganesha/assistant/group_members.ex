defmodule Ganesha.Assistant.GroupMembers do
  @moduledoc """
  LINE group members as Students (spec 2026-10-19-november-launch-design.md
  §1-2): resolves a member and, when that made or may make them a Student,
  enqueues the teachers' notice in the same transaction; tags each group
  message with who sent it for the model.
  """

  import Ecto.Query

  alias Ganesha.{Assistant, Line, People, Repo}
  alias Ganesha.Assistant.MemberNoticeWorker
  alias Ganesha.People.{LineMember, Student}

  @doc """
  Resolves a group member with `Ganesha.People.resolve_line_member/2`, or
  `:skipped` for a teacher. A `created`, `linked` or `unsure` result enqueues
  one `MemberNoticeWorker` job in the same transaction.
  """
  @spec resolve(String.t(), String.t()) :: People.resolution() | :skipped
  def resolve(line_user_id, display_name)
      when is_binary(line_user_id) and is_binary(display_name) do
    if Line.teacher?(line_user_id) do
      :skipped
    else
      {:ok, resolution} =
        Repo.transaction(fn ->
          resolution = People.resolve_line_member(line_user_id, display_name)
          notify(resolution, line_user_id, String.trim(display_name))
          resolution
        end)

      resolution
    end
  end

  @doc """
  Prefixes each user message that has a sender and content with a tag naming
  the sender from current data: `[student <id> <name>]`, `[LINE <name>, not a
  student]`, or `[LINE <name>, unmatched]`. Only the given structs change,
  never the stored messages.
  """
  @spec tag_history([Assistant.Message.t()]) :: [Assistant.Message.t()]
  def tag_history(messages) do
    sender_ids =
      for %{role: "user", sender_id: id, content: content} <- messages,
          is_binary(id) and is_binary(content),
          uniq: true,
          do: id

    students =
      from(s in Student, where: s.line_user_id in ^sender_ids)
      |> Repo.all()
      |> Map.new(&{&1.line_user_id, &1})

    not_students =
      from(m in LineMember,
        where: m.line_user_id in ^sender_ids and m.state == "not_student",
        select: m.line_user_id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.map(messages, &tag(&1, students, not_students))
  end

  defp tag(%{role: "user", sender_id: id, content: content} = message, students, not_students)
       when is_binary(id) and is_binary(content) do
    %{message | content: sender_tag(message, students, not_students) <> " " <> content}
  end

  defp tag(message, _students, _not_students), do: message

  defp sender_tag(%{sender_id: id, sender_name: name}, students, not_students) do
    case students do
      %{^id => student} ->
        "[student #{student.id} #{student.display_name}]"

      _ ->
        if MapSet.member?(not_students, id),
          do: "[LINE #{name || "unknown"}, not a student]",
          else: "[LINE #{name || "unknown"}, unmatched]"
    end
  end

  defp notify({kind, _} = resolution, line_user_id, display_name)
       when kind in [:created, :linked, :unsure] do
    {:ok, _job} =
      resolution
      |> MemberNoticeWorker.args(line_user_id, display_name)
      |> MemberNoticeWorker.new()
      |> Oban.insert()

    :ok
  end

  defp notify(_resolution, _line_user_id, _display_name), do: :ok
end
