defmodule Ganesha.Assistant.Tools.ProposePaymentDraft do
  @moduledoc """
  Creates a pending payment draft (spec §4, §5). Supplying `purchase_id` is
  optional here — an agent that has already called `student_history` can
  resolve it itself; when omitted, `Ganesha.Assistant.apply_draft/2` refuses
  to guess and routes the teacher to the in-app edit flow instead.
  """
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.Assistant

  @impl true
  def name, do: "propose_payment_draft"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Proposes a draft payment for the teacher to confirm. Never applies itself.",
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          purchase_id: %{type: "integer"},
          amount: %{type: "integer"},
          method: %{type: "string", enum: ["line_pay", "line_bank", "cash", "other"]},
          paid_on: %{type: "string", description: "ISO 8601 date"},
          reported_last5: %{type: "string"},
          note: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["amount", "method"]
      }
    }
  end

  @impl true
  def call(input, thread) do
    {confidence, parsed} = Map.pop(input, "confidence", 1.0)
    student_id = Map.get(parsed, "student_id")

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "payment",
        student_id: student_id,
        parsed: Map.delete(parsed, "student_id"),
        confidence: confidence
      })

    {"draft ##{draft.id} created (payment, pending confirmation)", draft.id}
  end
end
