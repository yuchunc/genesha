defmodule Ganesha.Assistant.ProcessEventWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Catalog, Line, People, Sales}
  alias Ganesha.Assistant.{Digest, DraftNotifier, ProcessEventWorker}
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Line.Client.Mock, as: LineMock
  alias Ganesha.Line.Labels

  @teacher "Uteacher0000000000000000000000"
  @other_teacher "Uteacher2000000000000000000000"

  # Records a webhook event and runs its job inline; returns the job's result
  # and the stored event.
  defp deliver(event) do
    webhook_event_id = "evt-#{System.unique_integer([:positive])}"

    :ok =
      Line.record_event(
        Map.merge(%{"webhookEventId" => webhook_event_id, "mode" => "active"}, event)
      )

    line_event = Repo.get_by!(Line.LineEvent, webhook_event_id: webhook_event_id)
    {perform_job(ProcessEventWorker, %{"line_event_id" => line_event.id}), line_event}
  end

  defp new_line_message_id, do: "linemsg-#{System.unique_integer([:positive])}"

  defp text_from(user_id, text) do
    line_message_id = new_line_message_id()

    %{
      "type" => "message",
      "replyToken" => "rt-1",
      "source" => %{"type" => "user", "userId" => user_id},
      "message" => %{"id" => line_message_id, "type" => "text", "text" => text}
    }
  end

  defp group_text(sender_id, text, line_message_id \\ new_line_message_id()) do
    %{
      "type" => "message",
      "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => sender_id},
      "message" => %{"id" => line_message_id, "type" => "text", "text" => text}
    }
  end

  defp postback_from(user_id, data) do
    %{
      "type" => "postback",
      "replyToken" => "rt-p",
      "source" => %{"type" => "user", "userId" => user_id},
      "postback" => %{"data" => data}
    }
  end

  defp group_source(sender_id),
    do: %{"type" => "group", "groupId" => "Cabc", "userId" => sender_id}

  defp teacher_thread do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
    thread
  end

  defp lulu do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1200})

    student
  end

  defp payment_call(id, student, amount) do
    %{
      id: id,
      name: "record_payment",
      input: %{"student_id" => student.id, "amount" => amount, "method" => "line_pay"}
    }
  end

  describe "1:1 chats" do
    test "a teacher message runs a Conversation turn and marks the event processed" do
      thread = teacher_thread()
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "目前沒有人欠錢。", tool_calls: []}} end)

      assert {:ok, line_event} = deliver(text_from(@teacher, "誰欠錢？"))

      assert [
               {:loading, {@teacher, 20}},
               {:reply, {"rt-1", [%{type: "text", text: "目前沒有人欠錢。"}]}}
             ] = LineMock.calls()

      assert [%{content: "誰欠錢？"}, %{content: "目前沒有人欠錢。"}] = Assistant.list_messages(thread)
      assert Line.get_event!(line_event.id).processed_at
    end

    test "asks a new 1:1 sender to choose a language before running the agent" do
      Mock.stub(fn _messages, _tools, _opts ->
        flunk("the agent ran before a language was chosen")
      end)

      assert {:ok, _} = deliver(text_from("Ustranger", "hi"))

      assert [{:reply, {"rt-1", [message]}}] = LineMock.calls()
      assert message == Line.Client.language_picker_message()
    end

    test "choosing the language answers the message that was waiting" do
      {:ok, _} = deliver(text_from("Ustranger2", "hi"))
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "Hello!", tool_calls: []}} end)

      assert {:ok, _} = deliver(postback_from("Ustranger2", "action=set_locale&locale=en"))

      assert Enum.any?(LineMock.calls(), fn
               {:reply, {"rt-p", [%{type: "text", text: "Hello!"}]}} -> true
               _ -> false
             end)
    end

    test "a teacher postback is settled by the Conversation" do
      thread = teacher_thread()

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

      assert {:ok, _} = deliver(postback_from(@teacher, "action=confirm&draft_id=#{draft.id}"))

      assert Assistant.get_draft!(draft.id).state == "applied"

      confirmed = Labels.t(:confirmed, "zh-TW", title: Assistant.draft_summary(draft, "zh-TW"))

      assert [{:reply, {"rt-p", [%{text: ^confirmed}]}}] = LineMock.calls()
    end

    test "the second teacher gets her own Teacher chat with the teacher's tasks" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", @other_teacher)
      {:ok, _} = Assistant.set_locale(thread, "zh-TW")

      Mock.stub(fn _messages, tools, _opts ->
        Process.put(:tool_names, Enum.map(tools, & &1.name))
        {:ok, %{text: "好", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(text_from(@other_teacher, "下一堂？"))

      assert "record_payment" in Process.get(:tool_names)
      assert [%{content: "下一堂？"}, %{content: "好"}] = Assistant.list_messages(thread)
      assert Assistant.list_messages(teacher_thread()) == []
    end

    test "either teacher can confirm a Draft proposed in the other's chat" do
      {:ok, draft} =
        Assistant.create_draft(teacher_thread(), %{
          kind: "makeup_request",
          parsed: %{"note" => "8/17"}
        })

      assert {:ok, _} =
               deliver(postback_from(@other_teacher, "action=confirm&draft_id=#{draft.id}"))

      assert Assistant.get_draft!(draft.id).state == "applied"
    end

    test "a non-teacher cannot confirm a Draft" do
      {:ok, draft} =
        Assistant.create_draft(teacher_thread(), %{
          kind: "makeup_request",
          parsed: %{"note" => "8/17"}
        })

      assert {:ok, _} = deliver(postback_from("Ustranger", "action=confirm&draft_id=#{draft.id}"))
      assert Assistant.get_draft!(draft.id).state == "pending"
    end

    test "a Student chat's sign-up request schedules the teachers' notifier" do
      {:ok, thread} = Assistant.get_or_create_thread("user", "Ustudent9")
      {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
      Process.put(:round, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        round = Process.get(:round)
        Process.put(:round, round + 1)

        if round == 0,
          do:
            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{id: "t1", name: "signup_request", input: %{"note" => "想報名週一晚上"}}
               ]
             }},
          else: {:ok, %{text: "老師會親自回覆你喔！", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(text_from("Ustudent9", "我想報名週一晚上的課"))

      assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => thread.id})
    end

    test "a Student chat turn without a Draft schedules nothing" do
      {:ok, thread} = Assistant.get_or_create_thread("user", "Ustudent10")
      {:ok, _} = Assistant.set_locale(thread, "zh-TW")
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "你好！", tool_calls: []}} end)

      assert {:ok, _} = deliver(text_from("Ustudent10", "你好"))

      refute_enqueued(worker: DraftNotifier)
    end

    test "a Student chat turn without a new Draft leaves the waiting notifier where it was" do
      {:ok, thread} = Assistant.get_or_create_thread("user", "Ustudent11")
      {:ok, thread} = Assistant.set_locale(thread, "zh-TW")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "signup_request",
          parsed: %{"note" => "想報名週一晚上", "line_user_id" => "Ustudent11", "new" => true}
        })

      # The draft came four minutes ago.
      four_minutes_ago = DateTime.utc_now() |> DateTime.add(-240) |> DateTime.truncate(:second)

      Repo.update_all(from(d in Assistant.Draft, where: d.id == ^draft.id),
        set: [inserted_at: four_minutes_ago]
      )

      :ok = DraftNotifier.schedule_if_pending(thread)
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "在喔！", tool_calls: []}} end)

      assert {:ok, _} = deliver(text_from("Ustudent11", "還在嗎？"))

      assert [job] = all_enqueued(worker: DraftNotifier, args: %{"thread_id" => thread.id})
      assert DateTime.diff(job.scheduled_at, four_minutes_ago) == 300
    end
  end

  describe "Group chat" do
    test "records a student's message and never calls LINE" do
      Mock.stub(fn _messages, _tools, _opts ->
        {:ok, %{text: "(internal reasoning, never sent)", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{role: "user", content: "2.Lulu （Line pay 1200元）"}, %{role: "assistant"}] =
               Assistant.list_messages(thread)
    end

    test "gives the model the Group chat's three tasks and the snapshot" do
      Mock.stub(fn _messages, tools, opts ->
        Process.put(:group_request, {Enum.map(tools, & &1.name), opts[:system]})
        {:ok, %{text: "nothing to do", tool_calls: []}}
      end)

      {:ok, _} = deliver(group_text("Ustudent1", "大家好"))

      {names, system} = Process.get(:group_request)
      assert names == ~w(record_payment book_one_off makeup_request)
      assert system =~ "Studio snapshot"
    end

    test "ignores the teacher's own posts in the group" do
      assert {:ok, _} = deliver(group_text(@teacher, "大家好"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert Assistant.list_messages(thread) == []
    end

    # TEMPORARY, DEV ONLY: see `dev_teacher_posts_in_groups` in config/runtime.exs.
    test "with the dev-only flag, a teacher's group post is handled like a student's" do
      line_config = Application.fetch_env!(:ganesha, :line)
      on_exit(fn -> Application.put_env(:ganesha, :line, line_config) end)

      Application.put_env(
        :ganesha,
        :line,
        Keyword.put(line_config, :dev_teacher_posts_in_groups, true)
      )

      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "ok", tool_calls: []}} end)

      assert {:ok, _} = deliver(group_text(@teacher, "大家好"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert [%{role: "user", sender_id: @teacher}, _] = Assistant.list_messages(thread)
    end

    test "can produce a pending Draft, never an applied one" do
      student = lulu()
      Process.put(:round, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        round = Process.get(:round)
        Process.put(:round, round + 1)

        if round == 0,
          do: {:ok, %{text: nil, tool_calls: [payment_call("t1", student, 1200)]}},
          else: {:ok, %{text: "logged internally", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      assert LineMock.calls() == []

      assert [%Assistant.Draft{state: "pending", kind: "record_payment"}] =
               Repo.all(Assistant.Draft)

      {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
      assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => group.id})
    end

    @tag :capture_log
    test "enqueues a notifier when the turn fails after creating a Draft" do
      student = lulu()
      Process.put(:round, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        round = Process.get(:round)
        Process.put(:round, round + 1)

        if round == 0,
          do: {:ok, %{text: nil, tool_calls: [payment_call("t1", student, 1200)]}},
          else: {:error, :overloaded}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))
      assert [%Assistant.Draft{state: "pending"}] = Repo.all(Assistant.Draft)
      {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
      assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => group.id})
    end

    test "does not enqueue a notifier when the group turn creates no Drafts" do
      Mock.stub(fn _messages, _tools, _opts ->
        {:ok, %{text: "logged internally", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "just chatting"))
      refute_enqueued(worker: DraftNotifier)
    end

    @tag :capture_log
    test "an agent failure returns :ok without retrying or duplicating the message" do
      Mock.stub(fn _messages, _tools, _opts -> {:error, :max_iterations_exceeded} end)

      assert {:ok, line_event} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert [%{role: "user"}] = Assistant.list_messages(thread)
      assert Line.get_event!(line_event.id).processed_at
    end

    test "stores the sender's id and LINE display name with the message" do
      Process.put(:line_client_mock_group_member, {:ok, %{"displayName" => "小美"}})
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "ok", tool_calls: []}} end)

      {:ok, _} = deliver(group_text("Ustudent1", "大家好"))

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{role: "user", sender_id: "Ustudent1", sender_name: "小美"}, _] =
               Assistant.list_messages(thread)
    end

    @tag :capture_log
    test "a failed member lookup still runs the agent, with no sender name" do
      Process.put(:line_client_mock_group_member, {:error, {404, %{}}})

      Mock.stub(fn _messages, _tools, _opts ->
        Process.put(:agent_ran, true)
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      {:ok, _} = deliver(group_text("Ustudent1", "大家好"))

      assert Process.get(:agent_ran)
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{sender_id: "Ustudent1", sender_name: nil}, _] =
               Assistant.list_messages(thread)
    end

    test "a blocked group is dropped before anything is stored or looked up" do
      {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "測試群組"})

      Mock.stub(fn _messages, _tools, _opts ->
        Process.put(:agent_ran, true)
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      refute Process.get(:agent_ran)
      assert LineMock.lookups() == []
      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert Assistant.list_messages(thread) == []
    end

    test "a blocked sender is dropped in every group" do
      {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Uspam", label: "廣告"})

      Mock.stub(fn _messages, _tools, _opts ->
        Process.put(:agent_ran, true)
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      other_group = %{
        "type" => "message",
        "source" => %{"type" => "group", "groupId" => "Cother", "userId" => "Uspam"},
        "message" => %{"id" => new_line_message_id(), "type" => "text", "text" => "買課送課"}
      }

      assert {:ok, _} = deliver(group_text("Uspam", "買課送課"))
      assert {:ok, _} = deliver(other_group)

      refute Process.get(:agent_ran)
      assert LineMock.lookups() == []

      for group_id <- ["Cabc", "Cother"] do
        {:ok, thread} = Assistant.get_or_create_thread("group", group_id)
        assert Assistant.list_messages(thread) == []
      end
    end
  end

  describe "unsend and messageEdited" do
    setup do
      student = lulu()
      Process.put(:round, 0)

      # Round 0 proposes 900; after an edit, round 2 proposes 1200.
      Mock.stub(fn _messages, _tools, _opts ->
        round = Process.get(:round)
        Process.put(:round, round + 1)

        case round do
          0 -> {:ok, %{text: nil, tool_calls: [payment_call("t1", student, 900)]}}
          2 -> {:ok, %{text: nil, tool_calls: [payment_call("t2", student, 1200)]}}
          _ -> {:ok, %{text: "logged", tool_calls: []}}
        end
      end)

      {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 900元）", "linemsg-1"))
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      [draft] = Repo.all(Assistant.Draft)
      %{thread: thread, draft: draft}
    end

    test "unsend clears the message's text and discards its pending Draft", c do
      assert {:ok, _} =
               deliver(%{
                 "type" => "unsend",
                 "source" => group_source("Ustudent1"),
                 "unsend" => %{"messageId" => "linemsg-1"}
               })

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert is_nil(user_message.content)
      assert Assistant.get_draft!(c.draft.id).state == "discarded"
    end

    test "messageEdited replaces the pending Draft with one from the corrected text", c do
      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => group_source("Ustudent1"),
                 "message" => %{"id" => "linemsg-1", "text" => "2.Lulu （Line pay 1200元）"}
               })

      assert Assistant.get_draft!(c.draft.id).state == "discarded"

      assert [%{parsed: %{"amount" => 1200}}] =
               Repo.all(from d in Assistant.Draft, where: d.state == "pending")

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end

    test "messageEdited in a blocked group updates the text without re-running the agent", c do
      {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "測試群組"})

      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => group_source("Ustudent1"),
                 "message" => %{"id" => "linemsg-1", "text" => "2.Lulu （Line pay 1200元）"}
               })

      assert Process.get(:round) == 2
      assert Assistant.get_draft!(c.draft.id).state == "discarded"
      assert Repo.all(from d in Assistant.Draft, where: d.state == "pending") == []

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end

    test "messageEdited from a blocked sender updates the text without re-running the agent",
         c do
      {:ok, _} =
        Line.block_account(%{kind: "sender", line_id: "Ustudent1", label: "測試學生"})

      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => group_source("Ustudent1"),
                 "message" => %{"id" => "linemsg-1", "text" => "2.Lulu （Line pay 1200元）"}
               })

      assert Process.get(:round) == 2
      assert Assistant.get_draft!(c.draft.id).state == "discarded"
      assert Repo.all(from d in Assistant.Draft, where: d.state == "pending") == []

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.sender_id == "Ustudent1"
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end

    test "messageEdited from a blocked sender is checked by the event's sender, not the stored one",
         c do
      c.thread
      |> Assistant.list_messages()
      |> Enum.find(&(&1.role == "user"))
      |> Ecto.Changeset.change(sender_id: nil)
      |> Repo.update!()

      {:ok, _} =
        Line.block_account(%{kind: "sender", line_id: "Ustudent1", label: "測試學生"})

      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => group_source("Ustudent1"),
                 "message" => %{"id" => "linemsg-1", "text" => "2.Lulu （Line pay 1200元）"}
               })

      assert Process.get(:round) == 2
      assert Repo.all(from d in Assistant.Draft, where: d.state == "pending") == []
    end
  end

  describe "Teacher chat digests" do
    setup do
      thread = teacher_thread()

      {:ok, message} =
        Assistant.append_message(thread, "user", "原本的話", nil, line_message_id: "linemsg-t1")

      message |> Ecto.Changeset.change(inserted_at: ~U[2026-09-24 04:00:00Z]) |> Repo.update!()

      daily =
        Repo.insert!(%Digest{
          thread_id: thread.id,
          kind: "daily",
          period_start: ~D[2026-09-24],
          period_end: ~D[2026-09-24],
          content: "d"
        })

      weekly =
        Repo.insert!(%Digest{
          thread_id: thread.id,
          kind: "weekly",
          period_start: ~D[2026-09-21],
          period_end: ~D[2026-09-27],
          content: "w"
        })

      %{thread: thread, daily: daily, weekly: weekly}
    end

    test "unsending a message drops the digests covering its day", c do
      assert {:ok, _} =
               deliver(%{
                 "type" => "unsend",
                 "source" => %{"type" => "user", "userId" => @teacher},
                 "unsend" => %{"messageId" => "linemsg-t1"}
               })

      refute Repo.reload(c.daily)
      refute Repo.reload(c.weekly)
    end

    test "editing a message drops them too and re-runs the turn", c do
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "改好了", tool_calls: []}} end)

      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => %{"type" => "user", "userId" => @teacher},
                 "message" => %{"id" => "linemsg-t1", "text" => "改過的話"}
               })

      refute Repo.reload(c.daily)
      refute Repo.reload(c.weekly)

      assert %{role: "assistant", content: "改好了"} = List.last(Assistant.list_messages(c.thread))
    end
  end
end
