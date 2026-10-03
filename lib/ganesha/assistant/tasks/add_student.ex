defmodule Ganesha.Assistant.Tasks.AddStudent do
  @moduledoc """
  `add_student` (spec §3.1 #19): create a student and optional aliases through
  `Ganesha.People.create_student/1` and `add_alias/2`, as the students index
  screen does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, People}

  @apply_keys ~w(display_name line_user_id aliases)

  @impl true
  def name, do: "add_student"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Add a new student to the studio. This only proposes a Draft; the student \
      (and any aliases) are created when the teacher taps Confirm. Aliases help \
      match LINE messages to this student later.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          display_name: %{type: "string"},
          line_user_id: %{type: "string", description: "Their LINE user id, if known"},
          aliases: %{
            type: "array",
            items: %{type: "string"},
            description: "Other names she uses for this student"
          }
        },
        required: ["display_name"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, display_name} <- require_name(input["display_name"]),
         {:ok, aliases} <- normalize_aliases(input["aliases"]),
         :ok <- validate_student(%{display_name: display_name, line_user_id: input["line_user_id"]}) do
      parsed = %{
        "display_name" => display_name,
        "line_user_id" => blank_to_nil(input["line_user_id"]),
        "aliases" => aliases
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <-
           People.create_student(%{
             display_name: attrs["display_name"],
             line_user_id: attrs["line_user_id"]
           }),
         :ok <- add_aliases(student, attrs["aliases"] || []) do
      {:ok, {"Ganesha.People.Student", student.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    %{
      title: "#{label(:title, locale)} #{parsed["display_name"]}",
      lines:
        Enum.reject(
          [
            line(:line_user_id, parsed["line_user_id"], locale),
            aliases_line(parsed["aliases"], locale)
          ],
          &is_nil/1
        ),
      changes: [],
      web_path: nil
    }
  end

  defp require_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "", do: {:error, "display_name is required"}, else: {:ok, trimmed}
  end

  defp require_name(_name), do: {:error, "display_name is required"}

  defp normalize_aliases(nil), do: {:ok, []}

  defp normalize_aliases(aliases) when is_list(aliases) do
    cleaned =
      aliases
      |> Enum.map(&if(is_binary(&1), do: String.trim(&1), else: ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, cleaned}
  end

  defp normalize_aliases(_aliases), do: {:error, "aliases must be a list of strings"}

  defp validate_student(attrs) do
    case %People.Student{} |> People.change_student(attrs) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _student} -> :ok
      {:error, changeset} -> {:error, Assistant.format_changeset_errors(changeset)}
    end
  end

  defp add_aliases(_student, []), do: :ok

  defp add_aliases(student, [alias | rest]) do
    case People.add_alias(student, alias) do
      {:ok, _} -> add_aliases(student, rest)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp label(:title, "en"), do: "Add student"
  defp label(:title, _), do: "新增學生"
  defp label(:line_user_id, "en"), do: "LINE user id"
  defp label(:line_user_id, _), do: "LINE 使用者 id"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp aliases_line([], _locale), do: nil
  defp aliases_line(aliases, "en"), do: "Aliases: #{Enum.join(aliases, ", ")}"
  defp aliases_line(aliases, _locale), do: "別名：#{Enum.join(aliases, "、")}"
end
