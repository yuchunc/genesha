defmodule Ganesha.Assistant.Tools.StudentBalance do
  @moduledoc "Reads a student's outstanding ledger balance (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{People, Reporting}

  @impl true
  def name, do: "student_balance"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Returns how much a student currently owes the studio.",
      input_schema: %{
        type: "object",
        properties: %{student_id: %{type: "integer"}},
        required: ["student_id"]
      }
    }
  end

  @impl true
  def call(%{"student_id" => student_id}, _thread) do
    case Enum.find(People.list_students(), &(&1.id == student_id)) do
      nil ->
        {"no student found matching #{inspect(student_id)}", nil}

      _student ->
        outstanding = Reporting.outstanding_for_student(student_id)
        {Jason.encode!(%{student_id: student_id, outstanding: outstanding}), nil}
    end
  end
end
