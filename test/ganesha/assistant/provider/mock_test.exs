defmodule Ganesha.Assistant.Provider.MockTest do
  use ExUnit.Case, async: true
  alias Ganesha.Assistant.Provider.Mock

  test "stub/1 controls what complete/3 returns" do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "hi", tool_calls: []}} end)
    assert {:ok, %{text: "hi", tool_calls: []}} = Mock.complete([], [], [])
  end

  test "complete/3 raises a clear error when no stub was registered" do
    assert_raise RuntimeError, ~r/stub\/1 was not called/, fn -> Mock.complete([], [], []) end
  end
end
