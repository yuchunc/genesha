defmodule Ganesha.Assistant.Tools.StudentHistory do
  @moduledoc "Reads a student's purchase and attendance history (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Roster, Sales}

  @impl true
  def name, do: "student_history"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Returns a student's purchases and attendance history.",
      input_schema: %{
        type: "object",
        properties: %{student_id: %{type: "integer"}},
        required: ["student_id"]
      }
    }
  end

  @impl true
  def call(%{"student_id" => student_id}, _thread) do
    purchases =
      student_id
      |> Sales.list_purchases_for_student()
      |> Enum.map(&%{id: &1.id, list_price: &1.list_price, custom_amount: &1.custom_amount})

    attendances =
      student_id
      |> Roster.list_for_student()
      |> Enum.map(&%{session_id: &1.session_id, kind: &1.kind, state: &1.state})

    {Jason.encode!(%{purchases: purchases, attendances: attendances}), nil}
  end
end
