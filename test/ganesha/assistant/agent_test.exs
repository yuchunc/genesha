defmodule Ganesha.Assistant.AgentTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Agent, Draft, Turn}
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Assistant.Tasks.{MakeupRequest, PendingDrafts}

  defmodule Echo do
    @behaviour Ganesha.Assistant.Task
    def name, do: "echo"
    def kind, do: :lookup

    def tool,
      do: %{
        description: "echoes",
        input_schema: %{type: "object", properties: %{text: %{type: "string"}}}
      }

    def answer(%{"text" => text}, _ctx), do: {:ok, %{data: "echoed: #{text}"}}
  end

  defmodule Pick do
    @behaviour Ganesha.Assistant.Task
    def name, do: "pick"
    def kind, do: :control

    def tool,
      do: %{description: "offers choices", input_schema: %{type: "object", properties: %{}}}

    def answer(_input, _ctx), do: {:ok, %{data: "choices shown", choices: ["A", "B"]}}
  end

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, user} = Assistant.append_message(thread, "user", "hello", nil)
    %{thread: thread, history: [user]}
  end

  defp call(id, name, input), do: %{id: id, name: name, input: input}

  # The model answers each round with the next list of tool calls, then with
  # "done". Every request's messages are kept so tests can read tool results.
  defp script(rounds) do
    Process.put(:rounds, rounds)
    Process.put(:requests, [])

    Mock.stub(fn messages, _tools, _opts ->
      Process.put(:requests, Process.get(:requests) ++ [messages])

      case Process.get(:rounds) do
        [calls | rest] ->
          Process.put(:rounds, rest)
          {:ok, %{text: nil, tool_calls: calls}}

        [] ->
          {:ok, %{text: "done", tool_calls: []}}
      end
    end)
  end

  defp tool_results do
    Process.get(:requests)
    |> List.last()
    |> Enum.filter(&(&1.role == "tool"))
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(& &1.content)
  end

  test "returns the model's final text as a Turn and persists it, naming the reply row", %{
    thread: thread,
    history: history
  } do
    script([[call("t1", "echo", %{"text" => "hi"})]])

    assert {:ok, %Turn{text: "done", draft_ids: [], choices: [], reply_message_id: id}} =
             Agent.run(thread, [Echo], "system", history)

    assert [_user, _calls, _results, %{id: ^id, role: "assistant", content: "done"}] =
             Assistant.list_messages(thread)
  end

  test "card lines the model copies from its history are neither returned nor stored", %{
    thread: thread,
    history: history
  } do
    Mock.stub(fn _messages, _tools, _opts ->
      {:ok, %{text: "還有 1 張草稿在等你。\n[草稿 #3 待確認] 照固定班排 11月 課表", tool_calls: []}}
    end)

    assert {:ok, %Turn{text: "還有 1 張草稿在等你。", reply_message_id: id}} =
             Agent.run(thread, [Echo], "system", history)

    assert %{content: "還有 1 張草稿在等你。"} = Enum.find(Assistant.list_messages(thread), &(&1.id == id))
  end

  test "sends the given history, every message with tool_calls present", %{thread: thread} do
    {:ok, reply} = Assistant.append_message(thread, "assistant", "earlier reply", nil)
    {:ok, question} = Assistant.append_message(thread, "user", "and now?", nil)
    script([])

    {:ok, _} = Agent.run(thread, [Echo], "system", [reply, question])

    assert [
             [
               %{role: "assistant", content: "earlier reply", tool_calls: []},
               %{role: "user", content: "and now?", tool_calls: []}
             ]
           ] = Process.get(:requests)
  end

  test "a change task becomes a pending Draft whose id joins the Turn", %{
    thread: thread,
    history: history
  } do
    script([[call("t1", "makeup_request", %{"note" => "想補 8/17"})]])

    assert {:ok, %Turn{draft_ids: [id]}} = Agent.run(thread, [MakeupRequest], "system", history)

    assert %Draft{kind: "makeup_request", state: "pending", parsed: %{"note" => "想補 8/17"}} =
             Repo.get!(Draft, id)

    assert tool_results() == ["draft ##{id} created (makeup_request, pending confirmation)"]
  end

  test "a propose/2 error goes back to the model and writes nothing", %{
    thread: thread,
    history: history
  } do
    script([[call("t1", "makeup_request", %{"note" => " "})]])

    assert {:ok, %Turn{draft_ids: []}} = Agent.run(thread, [MakeupRequest], "system", history)
    {:error, reason} = MakeupRequest.propose(%{"note" => " "}, %{})
    assert tool_results() == [reason]
    assert Repo.aggregate(Draft, :count) == 0
  end

  test "replaces_draft_id replaces the earlier Draft", %{thread: thread, history: history} do
    {:ok, old} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

    script([[call("t1", "makeup_request", %{"note" => "8/24", "replaces_draft_id" => old.id})]])

    assert {:ok, %Turn{draft_ids: [new_id]}} =
             Agent.run(thread, [MakeupRequest], "system", history)

    assert %Draft{state: "replaced", replaced_by_id: ^new_id} = Repo.reload!(old)
  end

  test "replaces_draft_id sent as a string of digits still replaces the earlier Draft", %{
    thread: thread,
    history: history
  } do
    {:ok, old} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

    input = %{"note" => "8/24", "replaces_draft_id" => Integer.to_string(old.id)}
    script([[call("t1", "makeup_request", input)]])

    assert {:ok, %Turn{draft_ids: [new_id]}} =
             Agent.run(thread, [MakeupRequest], "system", history)

    assert %Draft{state: "replaced", replaced_by_id: ^new_id} = Repo.reload!(old)
  end

  test "a Draft corrected later in the same turn leaves the Turn", %{
    thread: thread,
    history: history
  } do
    Process.put(:round, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      round = Process.get(:round)
      Process.put(:round, round + 1)

      case round do
        0 ->
          {:ok, %{text: nil, tool_calls: [call("t1", "makeup_request", %{"note" => "8/17"})]}}

        1 ->
          first = Repo.one!(from d in Draft, where: d.thread_id == ^thread.id)
          input = %{"note" => "8/24", "replaces_draft_id" => first.id}
          {:ok, %{text: nil, tool_calls: [call("t2", "makeup_request", input)]}}

        _ ->
          {:ok, %{text: "done", tool_calls: []}}
      end
    end)

    assert {:ok, %Turn{draft_ids: [id]}} = Agent.run(thread, [MakeupRequest], "system", history)
    assert Repo.get!(Draft, id).parsed["note"] == "8/24"
  end

  test "a lookup's draft_ids join the Turn", %{thread: thread, history: history} do
    {:ok, draft} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

    script([[call("t1", "pending_drafts", %{})]])

    assert {:ok, %Turn{draft_ids: [id]}} =
             Agent.run(thread, [PendingDrafts], "system", history)

    assert id == draft.id
  end

  test "a control task's choices become the Turn's choices", %{thread: thread, history: history} do
    script([[call("t1", "pick", %{})]])
    assert {:ok, %Turn{choices: ["A", "B"]}} = Agent.run(thread, [Pick], "system", history)
  end

  test "an unknown tool name is reported back to the model", %{thread: thread, history: history} do
    script([[call("t1", "nonexistent", %{})]])

    assert {:ok, %Turn{text: "done"}} = Agent.run(thread, [Echo], "system", history)
    assert tool_results() == ["unknown tool: nonexistent"]
  end

  test "stops after six rounds", %{thread: thread, history: history} do
    Process.put(:calls, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      Process.put(:calls, Process.get(:calls) + 1)
      {:ok, %{text: nil, tool_calls: [call("t", "echo", %{"text" => "x"})]}}
    end)

    assert {:error, :max_iterations_exceeded} = Agent.run(thread, [Echo], "system", history)
    assert Process.get(:calls) == 6
  end

  test "Draft ids keep call order within a round", %{thread: thread, history: history} do
    script([
      [
        call("t1", "makeup_request", %{"note" => "a"}),
        call("t2", "makeup_request", %{"note" => "b"})
      ]
    ])

    assert {:ok, %Turn{draft_ids: ids}} = Agent.run(thread, [MakeupRequest], "system", history)
    assert length(ids) == 2

    assert ids ==
             Repo.all(
               from d in Draft, where: d.thread_id == ^thread.id, order_by: d.id, select: d.id
             )
  end

  test "persists the tool round so later turns can replay it", %{thread: thread, history: history} do
    script([[call("t1", "echo", %{"text" => "a"})]])

    {:ok, _} = Agent.run(thread, [Echo], "system", history)

    assert ["user", "assistant", "tool", "assistant"] =
             Enum.map(Assistant.list_messages(thread), & &1.role)
  end
end
