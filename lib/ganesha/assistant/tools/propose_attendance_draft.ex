defmodule Ganesha.Assistant.Tools.ProposeAttendanceDraft do
  @moduledoc "Creates a pending attendance draft (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Assistant, People}

  @impl true
  def name, do: "propose_attendance_draft"

  @impl true
  def schema do
    %{
      name: name(),
      description:
        "Proposes a draft attendance change for the teacher to confirm. A real makeup " <>
          "(kind \"makeup\") is never proposed here — use propose_makeup_draft instead, " <>
          "since booking a makeup must consume a credit and only a human confirming an " <>
          "in-app makeup flow can do that.",
      input_schema: %{
        type: "object",
        properties: %{
          session_id: %{type: "integer"},
          student_id: %{type: "integer"},
          kind: %{type: "string", enum: ["enrolled", "drop_in", "trial"]},
          note: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["session_id", "student_id", "kind"]
      }
    }
  end

  @impl true
  def call(input, thread) do
    {confidence, parsed} = Map.pop(input, "confidence", 1.0)
    student_id = Map.get(parsed, "student_id")

    case resolve_student(student_id) do
      {:error, message} ->
        {message, nil}

      :ok ->
        {:ok, draft} =
          Assistant.create_draft(thread, %{
            kind: "attendance",
            student_id: student_id,
            parsed: parsed,
            confidence: confidence
          })

        {"draft ##{draft.id} created (attendance, pending confirmation)", draft.id}
    end
  end

  defp resolve_student(nil), do: :ok

  defp resolve_student(student_id) do
    if Enum.any?(People.list_students(), &(&1.id == student_id)) do
      :ok
    else
      {:error, "no student found with id #{student_id}"}
    end
  end
end
