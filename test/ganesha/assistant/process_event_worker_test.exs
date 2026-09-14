defmodule Ganesha.Assistant.ProcessEventWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Catalog, Line, People, Sales}
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
        "message" => %{
          "id" => "linemsg-#{System.unique_integer([:positive])}",
          "type" => "text",
          "text" => text
        }
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    job
  end

  defp enqueue_group_message(sender_id, text) do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-#{System.unique_integer([:positive])}",
        "type" => "message",
        "mode" => "active",
        "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => sender_id},
        "message" => %{
          "id" => "linemsg-#{System.unique_integer([:positive])}",
          "type" => "text",
          "text" => text
        }
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    job
  end

  defp enqueue_teacher_postback(data) do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-#{System.unique_integer([:positive])}",
        "type" => "postback",
        "mode" => "active",
        "source" => %{"type" => "user", "userId" => "Uteacher0000000000000000000000"},
        "replyToken" => "rt-postback",
        "postback" => %{"data" => data}
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
      defdelegate text_message(text, draft_id \\ nil), to: Ganesha.Line.Client
    end

    Application.put_env(:ganesha, :line_client, ExpiredReplyLineMock)
    on_exit(fn -> Application.put_env(:ganesha, :line_client, LineMock) end)

    job = enqueue_teacher_message("你好")
    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:push, {"Uteacher0000000000000000000000", [%{type: "text", text: "好的"}]}}] =
             LineMock.calls()
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

  test "replies with an apology and returns :ok when the agent run fails, instead of retrying and duplicating the message" do
    Mock.stub(fn _messages, _tools, _opts -> {:error, :max_iterations_exceeded} end)
    job = enqueue_teacher_message("誰欠錢？")

    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:reply, {"rt-1", [%{type: "text", text: apology}]}}] = LineMock.calls()
    assert apology =~ "抱歉"

    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    assert [%{content: "誰欠錢？"}] = Assistant.list_messages(thread)

    line_event = Line.get_event!(job.args["line_event_id"])
    assert line_event.processed_at
  end

  test "attaches a confirm/discard action for every draft the turn created, not just the first" do
    Mock.stub(fn messages, _tools, _opts ->
      if Enum.any?(messages, &(&1.role == "tool")) do
        {:ok, %{text: "已記錄兩筆", tool_calls: []}}
      else
        {:ok,
         %{
           text: nil,
           tool_calls: [
             %{id: "t1", name: "propose_makeup_draft", input: %{"note" => "8/17 補課"}},
             %{id: "t2", name: "propose_makeup_draft", input: %{"note" => "8/24 補課"}}
           ]
         }}
      end
    end)

    job = enqueue_teacher_message("兩個學生都要補課")
    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:reply, {"rt-1", [main, followup]}}] = LineMock.calls()
    assert main.text == "已記錄兩筆"
    assert [confirm1, _discard1] = main.quickReply.items
    assert followup.text == "另一筆草稿待確認"
    assert [confirm2, _discard2] = followup.quickReply.items
    refute confirm1.action.data == confirm2.action.data
  end

  describe "group thread" do
    test "processes a student message into thread history without ever calling Line.Client" do
      Mock.stub(fn _messages, _tools, _opts ->
        {:ok, %{text: "(internal reasoning, never sent)", tool_calls: []}}
      end)

      job = enqueue_group_message("Ustudent1", "2.Lulu （Line pay 1200元）")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{role: "user", content: "2.Lulu （Line pay 1200元）"}, %{role: "assistant"}] =
               Assistant.list_messages(thread)
    end

    test "the teacher's own posts in the group are not treated as student input" do
      job = enqueue_group_message("Uteacher0000000000000000000000", "大家好")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert Assistant.list_messages(thread) == []
    end

    test "a group message can still produce a pending draft, never an applied one" do
      Process.put(:calls, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        case Process.get(:calls) do
          0 ->
            Process.put(:calls, 1)

            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{
                   id: "t1",
                   name: "propose_payment_draft",
                   input: %{"amount" => 1200, "method" => "line_pay", "confidence" => 0.8}
                 }
               ]
             }}

          1 ->
            {:ok, %{text: "logged internally", tool_calls: []}}
        end
      end)

      job = enqueue_group_message("Ustudent1", "2.Lulu （Line pay 1200元）")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      drafts = Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id))
      assert [%Assistant.Draft{state: "pending", kind: "payment"}] = drafts
    end

    test "agent failure returns :ok without retrying and duplicating the user message" do
      Mock.stub(fn _messages, _tools, _opts -> {:error, :max_iterations_exceeded} end)

      job = enqueue_group_message("Ustudent1", "2.Lulu （Line pay 1200元）")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{role: "user", content: "2.Lulu （Line pay 1200元）"}] =
               Assistant.list_messages(thread)

      line_event = Line.get_event!(job.args["line_event_id"])
      assert line_event.processed_at
    end
  end

  describe "unsend and messageEdited" do
    test "unsend clears the message content and discards its pending draft" do
      Process.put(:calls, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        case Process.get(:calls) do
          0 ->
            Process.put(:calls, 1)

            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{
                   id: "t1",
                   name: "propose_payment_draft",
                   input: %{"amount" => 1200, "method" => "line_pay"}
                 }
               ]
             }}

          _ ->
            {:ok, %{text: "logged", tool_calls: []}}
        end
      end)

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-msg",
          "type" => "message",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => "Ustudent1"},
          "message" => %{
            "id" => "linemsg-1",
            "type" => "text",
            "text" => "2.Lulu （Line pay 1200元）"
          }
        })

      [msg_job] = all_enqueued(worker: ProcessEventWorker)
      assert :ok = perform_job(ProcessEventWorker, msg_job.args)

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      [draft] = Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id))
      assert draft.state == "pending"

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-unsend",
          "type" => "unsend",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => "Ustudent1"},
          "unsend" => %{"messageId" => "linemsg-1"}
        })

      [unsend_job] =
        all_enqueued(worker: ProcessEventWorker) |> Enum.reject(&(&1.id == msg_job.id))

      assert :ok = perform_job(ProcessEventWorker, unsend_job.args)

      user_message = Assistant.list_messages(thread) |> Enum.find(&(&1.role == "user"))
      assert is_nil(user_message.content)
      assert Assistant.get_draft!(draft.id).state == "discarded"
    end

    test "messageEdited replaces the pending draft with a fresh one from the corrected text" do
      Process.put(:calls, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        case Process.get(:calls) do
          0 ->
            Process.put(:calls, 1)

            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{
                   id: "t1",
                   name: "propose_payment_draft",
                   input: %{"amount" => 900, "method" => "line_pay"}
                 }
               ]
             }}

          1 ->
            Process.put(:calls, 2)
            {:ok, %{text: "logged", tool_calls: []}}

          2 ->
            Process.put(:calls, 3)

            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{
                   id: "t2",
                   name: "propose_payment_draft",
                   input: %{"amount" => 1200, "method" => "line_pay"}
                 }
               ]
             }}

          _ ->
            {:ok, %{text: "logged again", tool_calls: []}}
        end
      end)

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-msg2",
          "type" => "message",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cdef", "userId" => "Ustudent2"},
          "message" => %{
            "id" => "linemsg-2",
            "type" => "text",
            "text" => "2.Lulu （Line pay 900元）"
          }
        })

      [msg_job] = all_enqueued(worker: ProcessEventWorker)
      assert :ok = perform_job(ProcessEventWorker, msg_job.args)

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cdef")

      [original_draft] =
        Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id))

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-edit",
          "type" => "messageEdited",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cdef", "userId" => "Ustudent2"},
          "message" => %{"id" => "linemsg-2", "text" => "2.Lulu （Line pay 1200元）"}
        })

      [edit_job] = all_enqueued(worker: ProcessEventWorker) |> Enum.reject(&(&1.id == msg_job.id))
      assert :ok = perform_job(ProcessEventWorker, edit_job.args)

      assert Assistant.get_draft!(original_draft.id).state == "discarded"

      new_drafts =
        Ganesha.Repo.all(Assistant.Draft)
        |> Enum.filter(&(&1.thread_id == thread.id and &1.state == "pending"))

      assert [%{parsed: %{"amount" => 1200}}] = new_drafts

      user_message = Assistant.list_messages(thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end
  end

  describe "postback confirm/discard" do
    test "confirm applies a pending payment draft and replies with success" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "payment",
          parsed: %{
            "purchase_id" => purchase.id,
            "amount" => 400,
            "method" => "cash",
            "paid_on" => Date.to_iso8601(Ganesha.Clock.today())
          }
        })

      job = enqueue_teacher_postback("action=confirm&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "applied"
      assert [{:reply, {"rt-postback", [%{type: "text", text: "已確認並記錄。"}]}}] = LineMock.calls()
    end

    test "confirm on a draft missing purchase_id explains why, without applying" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "payment", parsed: %{"amount" => 400}})

      job = enqueue_teacher_postback("action=confirm&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "pending"
      assert [{:reply, {"rt-postback", [%{type: "text", text: text}]}}] = LineMock.calls()
      assert text =~ "App 內編輯"
    end

    test "discard marks a pending draft discarded" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})

      job = enqueue_teacher_postback("action=discard&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "discarded"
      assert [{:reply, {"rt-postback", [%{type: "text", text: "已捨棄。"}]}}] = LineMock.calls()
    end
  end
end
