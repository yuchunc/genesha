defmodule Ganesha.Assistant.Tools.ProposePaymentDraftTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tools.ProposePaymentDraft

  test "creates a pending payment draft on the thread" do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Assistant.append_message(thread, "user", "2.Lulu （Line pay 1200元）", nil)

    {content, draft_id} =
      ProposePaymentDraft.call(
        %{"amount" => 1200, "method" => "line_pay", "confidence" => 0.8},
        thread
      )

    assert content =~ "draft"
    draft = Assistant.get_draft!(draft_id)
    assert draft.kind == "payment"
    assert draft.state == "pending"
    assert draft.parsed["amount"] == 1200
    assert draft.confidence == 0.8
  end
end
