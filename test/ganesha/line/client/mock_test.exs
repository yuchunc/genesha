defmodule Ganesha.Line.Client.MockTest do
  use ExUnit.Case, async: true
  alias Ganesha.Line.Client
  alias Ganesha.Line.Client.Mock

  test "records reply and push calls for assertions" do
    assert :ok = Mock.reply("rt-1", [%{type: "text", text: "hi"}])
    assert :ok = Mock.push("U1", [%{type: "text", text: "hi"}])

    assert Mock.calls() == [
             {:reply, {"rt-1", [%{type: "text", text: "hi"}]}},
             {:push, {"U1", [%{type: "text", text: "hi"}]}}
           ]
  end

  test "get_group_member/2 returns a canned profile" do
    assert {:ok, %{"displayName" => _}} = Mock.get_group_member("Cabc", "U1")
  end

  test "text_message/1,2 delegates to Ganesha.Line.Client" do
    assert Mock.text_message("嗨") == Client.text_message("嗨")
    assert Mock.text_message("已建立草稿", 42) == Client.text_message("已建立草稿", 42)
  end
end
