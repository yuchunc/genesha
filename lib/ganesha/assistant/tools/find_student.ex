defmodule Ganesha.Assistant.Tools.FindStudent do
  @moduledoc "Resolves a free-text name or alias to a student (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.People

  @impl true
  def name, do: "find_student"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Finds a student by display name or known alias.",
      input_schema: %{
        type: "object",
        properties: %{query: %{type: "string"}},
        required: ["query"]
      }
    }
  end

  @impl true
  def call(%{"query" => query}, _thread) do
    case People.find_by_alias(query) do
      student when not is_nil(student) ->
        encode_student(student)

      nil ->
        matches = Enum.filter(People.list_students(), &(&1.display_name == query))

        case matches do
          [] -> {"no student found matching #{inspect(query)}", nil}
          [student] -> encode_student(student)
          multiple -> ambiguous_message(query, multiple)
        end
    end
  end

  defp encode_student(student) do
    payload = %{
      id: student.id,
      display_name: student.display_name,
      active: student.active
    }

    {Jason.encode!(payload), nil}
  end

  defp ambiguous_message(query, students) do
    candidates = Enum.map(students, &%{id: &1.id, display_name: &1.display_name})

    {"multiple students found matching #{inspect(query)}: #{Jason.encode!(candidates)}", nil}
  end
end
