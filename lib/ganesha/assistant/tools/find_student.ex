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
    student =
      People.find_by_alias(query) ||
        Enum.find(People.list_students(), &(&1.display_name == query))

    case student do
      nil -> {"no student found matching #{inspect(query)}", nil}
      student -> {Jason.encode!(%{id: student.id, display_name: student.display_name, active: student.active}), nil}
    end
  end
end
