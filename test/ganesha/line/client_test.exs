defmodule Ganesha.Line.ClientTest do
  use ExUnit.Case, async: true
  alias Ganesha.Line.Client

  test "text_message/1 builds a plain text message" do
    assert Client.text_message("嗨") == %{type: "text", text: "嗨"}
  end

  test "text_message/2 attaches a confirm/discard quick reply for a draft id" do
    message = Client.text_message("已建立草稿", 42)
    assert message.type == "text"
    assert [confirm, discard] = message.quickReply.items
    assert confirm.action.data == "action=confirm&draft_id=42"
    assert confirm.action.label == "確認"
    assert discard.action.data == "action=discard&draft_id=42"
    assert discard.action.label == "捨棄"
  end
end
