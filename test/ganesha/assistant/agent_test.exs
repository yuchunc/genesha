defmodule Ganesha.Assistant.AgentTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Agent
  alias Ganesha.Assistant.Provider.Mock

  defmodule EchoTool do
    @behaviour Ganesha.Assistant.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def schema, do: %{name: "echo", description: "echoes input", input_schema: %{}}

    @impl true
    def call(input, _thread), do: {"echoed: #{input["text"]}", nil}
  end

  defmodule DraftingTool do
    @behaviour Ganesha.Assistant.Tool

    @impl true
    def name, do: "draft_thing"

    @impl true
    def schema, do: %{name: "draft_thing", description: "creates a draft", input_schema: %{}}

    @impl true
    def call(_input, thread) do
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})
      {"draft created", draft.id}
    end
  end

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, _} = Assistant.append_message(thread, "user", "hello", nil)
    %{thread: thread}
  end

  test "returns the model's final text once it stops requesting tools", %{thread: thread} do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "hi there", tool_calls: []}} end)

    assert {:ok, %{text: "hi there", draft_ids: []}} =
             Agent.run(thread, [EchoTool], "system prompt")

    assert [_user, assistant] = Assistant.list_messages(thread)
    assert assistant.content == "hi there"
  end

  test "dispatches a tool call, feeds the result back, and returns any draft ids", %{
    thread: thread
  } do
    Process.put(:calls, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      case Process.get(:calls) do
        0 ->
          Process.put(:calls, 1)
          {:ok, %{text: nil, tool_calls: [%{id: "t1", name: "draft_thing", input: %{}}]}}

        1 ->
          {:ok, %{text: "done", tool_calls: []}}
      end
    end)

    assert {:ok, %{text: "done", draft_ids: [draft_id]}} =
             Agent.run(thread, [DraftingTool], "system prompt")

    assert Assistant.get_draft!(draft_id).state == "pending"
  end

  test "stops after the iteration cap rather than looping forever", %{thread: thread} do
    Mock.stub(fn _messages, _tools, _opts ->
      {:ok, %{text: nil, tool_calls: [%{id: "t", name: "echo", input: %{"text" => "x"}}]}}
    end)

    assert {:error, :max_iterations_exceeded} = Agent.run(thread, [EchoTool], "system prompt")
  end

  test "reports an unknown tool name without crashing", %{thread: thread} do
    Process.put(:calls, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      case Process.get(:calls) do
        0 ->
          Process.put(:calls, 1)
          {:ok, %{text: nil, tool_calls: [%{id: "t1", name: "nonexistent", input: %{}}]}}

        1 ->
          {:ok, %{text: "ok", tool_calls: []}}
      end
    end)

    assert {:ok, %{text: "ok", draft_ids: []}} = Agent.run(thread, [EchoTool], "system prompt")
  end
end
