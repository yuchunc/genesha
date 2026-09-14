defmodule Ganesha.Assistant.Tools.ProposeMakeupDraft do
  @moduledoc """
  Records that a student mentioned wanting a makeup, without a concrete
  session yet (spec §4, §5, original design §5.4's `makeup_request` kind).
  Applying this draft never books a makeup itself — only
  `Ganesha.Roster.book_makeup/3`, called from a human action once she
  picks a date, does that.
  """
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.Assistant

  @impl true
  def name, do: "propose_makeup_draft"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Records an unresolved makeup request the teacher will schedule by hand.",
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          note: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def call(input, thread) do
    {confidence, parsed} = Map.pop(input, "confidence", 1.0)
    student_id = Map.get(parsed, "student_id")

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "makeup_request",
        student_id: student_id,
        parsed: parsed,
        confidence: confidence
      })

    {"draft ##{draft.id} created (makeup request, pending confirmation)", draft.id}
  end
end
