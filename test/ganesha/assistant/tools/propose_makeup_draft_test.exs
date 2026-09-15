defmodule Ganesha.Assistant.Tools.ProposeMakeupDraftTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tools.ProposeMakeupDraft

  test "creates a pending makeup_request draft" do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Assistant.append_message(thread, "user", "蘭子補課8/17or 8/31", nil)

    {_content, draft_id} =
      ProposeMakeupDraft.call(%{"note" => "8/17 或 8/31", "confidence" => 0.5}, thread)

    draft = Assistant.get_draft!(draft_id)
    assert draft.kind == "makeup_request"
    assert draft.parsed["note"] == "8/17 或 8/31"
  end
end
