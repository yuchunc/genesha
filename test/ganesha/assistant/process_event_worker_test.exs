defmodule Ganesha.Assistant.ProcessEventWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.ProcessEventWorker
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Line.Client.Mock, as: LineMock

  defp enqueue_teacher_message(text) do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-#{System.unique_integer([:positive])}",
        "type" => "message",
        "mode" => "active",
        "source" => %{"type" => "user", "userId" => "Uteacher0000000000000000000000"},
        "replyToken" => "rt-1",
        "message" => %{"id" => "linemsg-#{System.unique_integer([:positive])}", "type" => "text", "text" => text}
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    job
  end

  test "answers via reply and marks the event processed" do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "目前沒有人欠錢。", tool_calls: []}} end)
    job = enqueue_teacher_message("誰欠錢？")

    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:reply, {"rt-1", [%{type: "text", text: "目前沒有人欠錢。"}]}}] = LineMock.calls()

    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    assert [%{content: "誰欠錢？"}, %{content: "目前沒有人欠錢。"}] = Assistant.list_messages(thread)

    line_event = Line.get_event!(job.args["line_event_id"])
    assert line_event.processed_at
  end

  test "falls back to push when the reply token has already expired" do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "好的", tool_calls: []}} end)

    defmodule ExpiredReplyLineMock do
      @behaviour Ganesha.Line.ClientBehaviour
      def reply(_reply_token, _messages), do: {:error, :expired}
      def push(to, messages), do: LineMock.push(to, messages)
      def get_group_member(g, u), do: LineMock.get_group_member(g, u)
    end

    Application.put_env(:ganesha, :line_client, ExpiredReplyLineMock)
    on_exit(fn -> Application.put_env(:ganesha, :line_client, LineMock) end)

    job = enqueue_teacher_message("你好")
    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:push, {"Uteacher0000000000000000000000", [%{type: "text", text: "好的"}]}}] = LineMock.calls()
  end

  test "ignores a message from a non-teacher 1:1 sender" do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-stranger",
        "type" => "message",
        "mode" => "active",
        "source" => %{"type" => "user", "userId" => "Ustranger"},
        "replyToken" => "rt-2",
        "message" => %{"id" => "linemsg-stranger", "type" => "text", "text" => "hi"}
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    assert :ok = perform_job(ProcessEventWorker, job.args)
    assert LineMock.calls() == []
  end
end
