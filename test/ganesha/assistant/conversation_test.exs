defmodule Ganesha.Assistant.ConversationTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Clock, People, Sales, Studio}
  alias Ganesha.Assistant.{Conversation, Draft, Tasks}
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Assistant.Tasks.{BookOneOff, MakeupRequest, RecordPayment, SignupRequest}
  alias Ganesha.Line.{Cards, Labels}
  alias Ganesha.Line.Client.Mock, as: LineMock
  alias Ganesha.Sales.Payment

  @teacher "Uteacher0000000000000000000000"

  defmodule ExpiredTokenLine do
    @behaviour Ganesha.Line.ClientBehaviour
    def reply(_token, _messages), do: {:error, {400, %{"message" => "Invalid reply token"}}}
    def push(to, messages), do: LineMock.push(to, messages)
    def loading(chat_id, seconds), do: LineMock.loading(chat_id, seconds)
    def validate_reply(messages), do: LineMock.validate_reply(messages)
    def get_group_member(group_id, user_id), do: LineMock.get_group_member(group_id, user_id)
    def get_group_summary(group_id), do: LineMock.get_group_summary(group_id)
    def get_profile(user_id), do: LineMock.get_profile(user_id)
  end

  defmodule RejectingLine do
    @behaviour Ganesha.Line.ClientBehaviour

    def reply(_token, _messages),
      do:
        {:error, {400, %{"message" => "A message (messages[1]) in the request body is invalid"}}}

    def push(to, messages), do: LineMock.push(to, messages)
    def loading(chat_id, seconds), do: LineMock.loading(chat_id, seconds)
    def validate_reply(messages), do: LineMock.validate_reply(messages)
    def get_group_member(group_id, user_id), do: LineMock.get_group_member(group_id, user_id)
    def get_group_summary(group_id), do: LineMock.get_group_summary(group_id)
    def get_profile(user_id), do: LineMock.get_profile(user_id)
  end

  # A Confirm postback that finishes while a turn is being delivered: its
  # outcome line lands in the Teacher chat after the turn's own reply.
  defmodule InterleavingLine do
    @behaviour Ganesha.Line.ClientBehaviour

    def reply(token, messages) do
      {:ok, thread} =
        Ganesha.Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

      {:ok, _} = Ganesha.Assistant.append_message(thread, "assistant", "outcome", nil)
      LineMock.reply(token, messages)
    end

    def push(to, messages), do: LineMock.push(to, messages)
    def loading(chat_id, seconds), do: LineMock.loading(chat_id, seconds)
    def validate_reply(messages), do: LineMock.validate_reply(messages)
    def get_group_member(group_id, user_id), do: LineMock.get_group_member(group_id, user_id)
    def get_group_summary(group_id), do: LineMock.get_group_summary(group_id)
    def get_profile(user_id), do: LineMock.get_profile(user_id)
  end

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 400})

    %{thread: thread, student: student}
  end

  defp use_line(module) do
    Application.put_env(:ganesha, :line_client, module)
    on_exit(fn -> Application.put_env(:ganesha, :line_client, LineMock) end)
  end

  defp say(thread, text) do
    {:ok, _} = Assistant.append_message(thread, "user", text, nil)
    thread
  end

  # The model makes `calls` in its first round, then answers `final`.
  defp model(calls, final) do
    Mock.stub(fn messages, tools, opts ->
      Process.put(:last_request, %{messages: messages, tools: tools, system: opts[:system]})

      if calls == [] or Enum.any?(messages, &(&1.role == "tool")),
        do: {:ok, %{text: final, tool_calls: []}},
        else: {:ok, %{text: nil, tool_calls: calls}}
    end)
  end

  defp record_payment_call(student) do
    %{
      id: "t1",
      name: "record_payment",
      input: %{"student_id" => student.id, "amount" => 400, "method" => "cash"}
    }
  end

  defp payment_draft(thread, student, overrides \\ %{}) do
    {:ok, %{parsed: parsed}} =
      RecordPayment.propose(
        %{"student_id" => student.id, "amount" => 400, "method" => "cash"},
        %{thread: thread, locale: "zh-TW", today: Clock.today()}
      )

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "record_payment",
        student_id: student.id,
        parsed: Map.merge(parsed, overrides)
      })

    draft
  end

  # A sign-up request as the Student chat would propose it.
  defp signup_draft(line_user_id) do
    {:ok, chat} = Assistant.get_or_create_thread("user", line_user_id)

    {:ok, %{student_id: student_id, parsed: parsed}} =
      SignupRequest.propose(%{"note" => "想報名週一晚上的課，11月開始"}, %{
        thread: chat,
        locale: "zh-TW",
        today: Clock.today()
      })

    {:ok, draft} =
      Assistant.create_draft(chat, %{
        kind: "signup_request",
        student_id: student_id,
        parsed: parsed
      })

    draft
  end

  defp enroll_tap(id), do: %{"action" => "enroll_from_request", "draft_id" => to_string(id)}

  defp makeup_tap(id), do: %{"action" => "book_from_request", "draft_id" => to_string(id)}

  defp makeup_draft(thread, student) do
    {:ok, %{student_id: student_id, parsed: parsed}} =
      MakeupRequest.propose(%{"student_id" => student.id, "note" => "想補 8/17"}, %{
        thread: thread,
        locale: "zh-TW",
        today: Clock.today()
      })

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "makeup_request",
        student_id: student_id,
        parsed: parsed
      })

    draft
  end

  defp postback(action, id), do: %{"action" => action, "draft_id" => to_string(id)}

  defp last_message(thread), do: thread |> Assistant.list_messages() |> List.last()

  defp title(draft, locale), do: Assistant.draft_summary(draft, locale)

  # The outcome line the model reads next turn (prompt rule 6: "[已確認] 草稿 #41 …").
  defp outcome_line(tag, draft, locale),
    do:
      "[#{Labels.t(tag, locale)}] #{Labels.t(:draft, locale)} ##{draft.id} #{title(draft, locale)}"

  describe "handle_message/3" do
    test "shows the loading animation, replies with the text and a Draft carousel, and records the card",
         %{thread: thread, student: student} do
      model([record_payment_call(student)], "已建立草稿，請確認。")

      assert :ok = Conversation.handle_message(say(thread, "Lulu 付了 400 現金"), "rt-1", @teacher)

      [draft] = Repo.all(Draft)

      assert [{:loading, {@teacher, 20}}, {:reply, {"rt-1", [text, flex]}}] = LineMock.calls()
      assert text == %{type: "text", text: "已建立草稿，請確認。"}
      assert %{type: "flex", contents: %{type: "carousel", contents: [bubble]}} = flex

      assert Enum.any?(
               bubble.footer.contents,
               &(&1.action[:data] == "action=confirm&draft_id=#{draft.id}")
             )

      assert last_message(thread).content ==
               "已建立草稿，請確認。\n" <> Cards.history_line({:draft, draft}, "zh-TW")
    end

    test "gives the model the snapshot, the Teacher chat's tasks and her history", %{
      thread: thread,
      student: student
    } do
      model([], "好")

      :ok = Conversation.handle_message(say(thread, "嗨"), "rt-1", @teacher)

      request = Process.get(:last_request)
      assert request.system =~ "- student #{student.id}: Lulu"

      assert Enum.map(request.tools, & &1.name) ==
               Enum.map(Tasks.for_chat(:teacher), & &1.name())

      assert "next_session" in Enum.map(request.tools, & &1.name)
      assert "pending_drafts" in Enum.map(request.tools, & &1.name)

      assert [%{role: "user", content: "嗨"}] = request.messages
    end

    test "a Student chat gets set_language and signup_request, and no snapshot" do
      {:ok, stranger} = Assistant.get_or_create_thread("user", "Ustranger")
      {:ok, stranger} = Assistant.set_locale(stranger, "en")
      model([], "Hello!")

      :ok = Conversation.handle_message(say(stranger, "hi"), "rt-2", "Ustranger")

      request = Process.get(:last_request)
      assert Enum.map(request.tools, & &1.name) == ["set_language", "signup_request"]
      refute request.system =~ "Studio snapshot"
      assert [{:loading, _}, {:reply, {"rt-2", [%{text: "Hello!"}]}}] = LineMock.calls()
    end

    test "a Student chat's sign-up request becomes a Draft, but the student gets text only" do
      {:ok, stranger} = Assistant.get_or_create_thread("user", "Ustranger")
      {:ok, stranger} = Assistant.set_locale(stranger, "zh-TW")

      model(
        [%{id: "t1", name: "signup_request", input: %{"note" => "想報名週一晚上"}}],
        "老師會親自回覆你喔！"
      )

      :ok = Conversation.handle_message(say(stranger, "我想報名週一晚上的課"), "rt-3", "Ustranger")

      assert [%Draft{kind: "signup_request", state: "pending"}] = Repo.all(Draft)

      assert [{:loading, _}, {:reply, {"rt-3", [%{type: "text", text: "老師會親自回覆你喔！"}]}}] =
               LineMock.calls()

      assert last_message(stranger).content == "老師會親自回覆你喔！"
    end

    test "after set_language the cards come back in the new language", %{thread: thread} do
      model(
        [
          %{id: "t1", name: "set_language", input: %{"locale" => "en"}},
          %{id: "t2", name: "makeup_request", input: %{"note" => "8/17"}}
        ],
        "Switched."
      )

      :ok = Conversation.handle_message(say(thread, "English please"), "rt-1", @teacher)

      assert [{:loading, _}, {:reply, {"rt-1", [_text, flex]}}] = LineMock.calls()
      [bubble] = flex.contents.contents

      assert Enum.map(bubble.footer.contents, & &1.action.label) ==
               [
                 Labels.t(:book_from_request, "en"),
                 Labels.t(:handled, "en"),
                 Labels.t(:discard, "en")
               ]
    end

    test "ask_teacher's options ride on the reply as quick replies", %{thread: thread} do
      model(
        [
          %{
            id: "t1",
            name: "ask_teacher",
            input: %{"question" => "哪一位？", "options" => ["Amy 王", "Amy 李"]}
          }
        ],
        "哪一位 Amy？"
      )

      :ok = Conversation.handle_message(say(thread, "Amy 付了"), "rt-1", @teacher)

      assert [{:loading, _}, {:reply, {"rt-1", [message]}}] = LineMock.calls()
      assert message.text == "哪一位 Amy？"
      assert Enum.map(message.quickReply.items, & &1.action.text) == ["Amy 王", "Amy 李"]
    end

    test "a lookup answer arrives as text only", %{thread: thread} do
      model([%{id: "t1", name: "next_session", input: %{}}], "下一堂是週四 19:00 基礎。")

      :ok = Conversation.handle_message(say(thread, "下一堂？"), "rt-1", @teacher)

      assert [{:loading, _}, {:reply, {"rt-1", messages}}] = LineMock.calls()
      assert Enum.all?(messages, &(&1.type == "text"))
      assert last_message(thread).content == "下一堂是週四 19:00 基礎。"
    end

    test "pushes the same messages when the reply token is no longer valid", %{thread: thread} do
      use_line(ExpiredTokenLine)
      model([], "好的")

      :ok = Conversation.handle_message(say(thread, "嗨"), "rt-1", @teacher)

      assert [{:loading, _}, {:push, {@teacher, [%{type: "text", text: "好的"}]}}] =
               LineMock.calls()
    end

    @tag :capture_log
    test "pushes a text-only version when LINE rejects the messages themselves", %{
      thread: thread,
      student: student
    } do
      use_line(RejectingLine)
      model([record_payment_call(student)], "已建立草稿。")

      :ok = Conversation.handle_message(say(thread, "Lulu 付了 400"), "rt-1", @teacher)

      [draft] = Repo.all(Draft)

      assert [{:loading, _}, {:push, {@teacher, [%{type: "text", text: text}]}}] =
               LineMock.calls()

      assert text == "已建立草稿。\n" <> Cards.history_line({:draft, draft}, "zh-TW")
    end

    @tag :capture_log
    test "apologizes in the chat's language when the agent fails", %{thread: thread} do
      {:ok, thread} = Assistant.set_locale(thread, "en")
      Mock.stub(fn _messages, _tools, _opts -> {:error, :max_iterations_exceeded} end)

      assert :ok = Conversation.handle_message(say(thread, "hi"), "rt-1", @teacher)

      apology = Labels.t(:apology, "en")
      assert [{:loading, _}, {:reply, {"rt-1", [%{text: ^apology}]}}] = LineMock.calls()
      assert [%{role: "user"}] = Assistant.list_messages(thread)
    end

    test "records the cards on the turn's own reply even when another message lands after it",
         %{thread: thread, student: student} do
      use_line(InterleavingLine)
      model([record_payment_call(student)], "已建立草稿。")

      :ok = Conversation.handle_message(say(thread, "Lulu 付了 400"), "rt-1", @teacher)

      [draft] = Repo.all(Draft)

      assert [%{content: reply}, %{content: "outcome"}] =
               thread |> Assistant.list_messages() |> Enum.take(-2)

      assert reply == "已建立草稿。\n" <> Cards.history_line({:draft, draft}, "zh-TW")
    end

    @tag :capture_log
    test "apologizes in the language the turn switched to before failing", %{thread: thread} do
      Mock.stub(fn messages, _tools, _opts ->
        if Enum.any?(messages, &(&1.role == "tool")),
          do: {:error, :overloaded},
          else:
            {:ok,
             %{
               text: nil,
               tool_calls: [%{id: "t1", name: "set_language", input: %{"locale" => "en"}}]
             }}
      end)

      :ok = Conversation.handle_message(say(thread, "English please"), "rt-1", @teacher)

      apology = Labels.t(:apology, "en")
      assert [{:loading, _}, {:reply, {"rt-1", [%{text: ^apology}]}}] = LineMock.calls()
    end
  end

  describe "handle_postback/4" do
    test "Confirm applies the Draft, says so, and tells the model", %{
      thread: thread,
      student: student
    } do
      draft = payment_draft(thread, student)

      assert :ok =
               Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher)

      assert Repo.reload!(draft).state == "applied"
      confirmed = Labels.t(:confirmed, "zh-TW", title: title(draft, "zh-TW"))
      assert [{:reply, {"rt-p", [%{type: "text", text: ^confirmed}]}}] = LineMock.calls()
      assert last_message(thread).content == outcome_line(:tag_confirmed, draft, "zh-TW")
    end

    test "Confirm records which teacher confirmed", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok = Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher)

      assert [%Payment{confirmed_by: confirmed_by}] = Repo.all(Payment)
      assert confirmed_by == "line:" <> @teacher
    end

    test "a Draft that no longer applies is marked failed with the reason", %{
      thread: thread,
      student: student
    } do
      draft = payment_draft(thread, student, %{"purchase_id" => nil})

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher)

      failed = Repo.reload!(draft)
      assert failed.state == "failed"
      assert failed.failure_reason == "missing_purchase_id"

      expected =
        Labels.t(:failed, "zh-TW",
          title: title(draft, "zh-TW"),
          reason: Labels.failure_reason("missing_purchase_id", "zh-TW")
        )

      assert [{:reply, {"rt-p", [%{text: ^expected}]}}] = LineMock.calls()

      assert last_message(thread).content ==
               outcome_line(:tag_failed, draft, "zh-TW") <> " — missing_purchase_id"
    end

    test "a stale Draft fails with a readable reason, not the error code", %{thread: thread} do
      {:ok, student} = People.create_student(%{display_name: "Amy"})
      {:ok, pkg} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

      {:ok, %{parsed: parsed}} =
        Tasks.OverridePrice.propose(
          %{"purchase_id" => purchase.id, "custom_amount" => 1500},
          %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}
        )

      {:ok, draft} = Assistant.create_draft(thread, %{kind: "override_price", parsed: parsed})
      {:ok, _} = Sales.update_purchase(purchase, %{custom_amount: 1400})

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-1", @teacher)

      assert Repo.reload!(draft).failure_reason == "purchase_changed"
      assert [{:reply, {"rt-1", [%{text: text}]}}] = LineMock.calls()
      refute text =~ "purchase_changed"
      assert text =~ Labels.failure_reason(:purchase_changed, "zh-TW")
    end

    test "Discard discards the Draft", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("discard", draft.id), "rt-p", @teacher)

      assert Repo.reload!(draft).state == "discarded"
      discarded = Labels.t(:discarded, "zh-TW", title: title(draft, "zh-TW"))
      assert [{:reply, {"rt-p", [%{text: ^discarded}]}}] = LineMock.calls()
      assert last_message(thread).content == outcome_line(:tag_discarded, draft, "zh-TW")
    end

    test "a second tap says the Draft was already handled", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher)

      Process.delete(:line_client_mock_calls)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-q", @teacher)

      already = Labels.t(:already_handled, "zh-TW")
      assert [{:reply, {"rt-q", [%{text: ^already}]}}] = LineMock.calls()
      assert Repo.aggregate(Payment, :count) == 1
    end

    test "a replaced Draft says so", %{thread: thread, student: student} do
      old = payment_draft(thread, student)

      {:ok, _} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "x"}},
          replaces: old.id
        )

      :ok = Conversation.handle_postback(postback("confirm", old.id), "rt-p", @teacher)

      replaced = Labels.t(:replaced, "zh-TW")
      assert [{:reply, {"rt-p", [%{text: ^replaced}]}}] = LineMock.calls()
      assert Repo.reload!(old).state == "replaced"
    end

    test "an unknown Draft id" do
      :ok = Conversation.handle_postback(postback("confirm", 999_999), "rt-p", @teacher)
      :ok = Conversation.handle_postback(postback("discard", "abc"), "rt-q", @teacher)

      not_found = Labels.t(:not_found, "zh-TW")

      assert [
               {:reply, {"rt-p", [%{text: ^not_found}]}},
               {:reply, {"rt-q", [%{text: ^not_found}]}}
             ] = LineMock.calls()
    end

    @tag :capture_log
    test "an exception leaves the Draft pending and asks her to try again", %{thread: thread} do
      {:ok, amy} = People.create_student(%{display_name: "Amy"})

      {:ok, slot} =
        Studio.create_slot(%{
          weekday: 3,
          start_time: ~T[19:00:00],
          end_time: ~T[20:15:00],
          default_style: "Hatha",
          label: "基礎"
        })

      {:ok, session} =
        Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

      {:ok, trial} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 300})

      {:ok, %{parsed: parsed}} =
        BookOneOff.propose(
          %{"student_id" => amy.id, "session_id" => session.id, "package_id" => trial.id},
          %{thread: thread, locale: "zh-TW", today: Clock.today()}
        )

      # A negative custom amount makes Enrolling.add_one_off/4 raise mid-apply.
      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "book_one_off",
          student_id: amy.id,
          parsed: Map.put(parsed, "custom_amount", -5)
        })

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher)

      assert Repo.reload!(draft).state == "pending"
      exception = Labels.t(:exception, "zh-TW")
      assert [{:reply, {"rt-p", [%{text: ^exception}]}}] = LineMock.calls()
      assert last_message(thread).content == outcome_line(:tag_exception, draft, "zh-TW")
    end

    test "only the teacher may confirm", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-x", "Ustranger")

      assert Repo.reload!(draft).state == "pending"
      unknown = Labels.t(:unknown_action, "zh-TW")
      assert [{:reply, {"rt-x", [%{text: ^unknown}]}}] = LineMock.calls()
    end

    test "outcomes follow the chat's language", %{thread: thread, student: student} do
      {:ok, thread} = Assistant.set_locale(thread, "en")
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher)

      confirmed = Labels.t(:confirmed, "en", title: title(draft, "en"))
      assert [{:reply, {"rt-p", [%{text: ^confirmed}]}}] = LineMock.calls()
      assert last_message(thread).content == outcome_line(:tag_confirmed, draft, "en")
    end

    test "choosing a language with nothing waiting welcomes the sender" do
      :ok =
        Conversation.handle_postback(
          %{"action" => "set_locale", "locale" => "en"},
          "rt-l",
          "Unew"
        )

      welcome = Labels.t(:welcome, "en")
      assert [{:reply, {"rt-l", [%{text: ^welcome}]}}] = LineMock.calls()
    end

    test "幫他報名 leaves the request pending and runs a turn in her chat", %{
      thread: thread
    } do
      {:ok, amy} = People.create_student(%{display_name: "Amy", line_user_id: "Uamy"})
      draft = signup_draft("Uamy")
      model([], "好，要幫 Amy 報名哪一堂？")

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-e", @teacher)

      assert Repo.reload!(draft).state == "pending"

      assert [request, reply] = Assistant.list_messages(thread)

      assert request.role == "user"
      assert request.content == SignupRequest.teacher_message(draft.id, draft.parsed, "zh-TW")
      assert request.content =~ "signup_request_id #{draft.id}"
      assert request.content =~ "##{amy.id}"
      assert reply.content == "好，要幫 Amy 報名哪一堂？"

      assert [{:loading, _}, {:reply, {"rt-e", [%{text: "好，要幫 Amy 報名哪一堂？"}]}}] =
               LineMock.calls()
    end

    test "幫他補課 leaves the request pending and runs a turn in her chat", %{
      thread: thread,
      student: student
    } do
      draft = makeup_draft(thread, student)
      model([], "要排哪一堂？")

      :ok = Conversation.handle_postback(makeup_tap(draft.id), "rt-m", @teacher)

      assert Repo.reload!(draft).state == "pending"

      assert [request, reply] = Assistant.list_messages(thread)
      assert request.role == "user"
      assert request.content == MakeupRequest.teacher_message(draft.id, draft.parsed, "zh-TW")
      assert request.content =~ "makeup_request_id #{draft.id}"
      assert reply.content == "要排哪一堂？"

      assert [{:loading, _}, {:reply, {"rt-m", [%{text: "要排哪一堂？"}]}}] = LineMock.calls()
    end

    test "an unlinked asker's request hands the model their LINE ID, not 'not a student'", %{
      thread: thread
    } do
      Process.put(:line_client_mock_profile, {:ok, %{"displayName" => "小美"}})
      draft = signup_draft("Unewcomer")
      model([], "名冊裡有小美嗎？")

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-e", @teacher)

      request = thread |> Assistant.list_messages() |> Enum.find(&(&1.role == "user"))
      assert request.content =~ "Unewcomer"
      assert request.content =~ "小美"
      assert request.content =~ "還沒連結任何學生"
      refute request.content =~ "還不是學生"
    end

    test "a request already handled says so and runs no turn", %{thread: thread} do
      draft = signup_draft("Unewcomer")
      {:ok, _} = Assistant.confirm_draft(draft, "line:" <> @teacher)
      Mock.stub(fn _messages, _tools, _opts -> flunk("no turn should run") end)

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-e", @teacher)

      handled = Labels.t(:already_handled, "zh-TW")
      assert [{:reply, {"rt-e", [%{text: ^handled}]}}] = LineMock.calls()
      refute Enum.any?(Assistant.list_messages(thread), &(&1.role == "user"))
    end

    test "幫他報名 on any other Draft is not found and changes nothing", %{
      thread: thread,
      student: student
    } do
      draft = payment_draft(thread, student)
      Mock.stub(fn _messages, _tools, _opts -> flunk("no turn should run") end)

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-e", @teacher)

      assert Repo.reload!(draft).state == "pending"
      not_found = Labels.t(:not_found, "zh-TW")
      assert [{:reply, {"rt-e", [%{text: ^not_found}]}}] = LineMock.calls()
    end

    test "only a teacher may tap 幫他報名 or 幫他補課", %{thread: thread, student: student} do
      signup = signup_draft("Unewcomer")
      makeup = makeup_draft(thread, student)
      Mock.stub(fn _messages, _tools, _opts -> flunk("no turn should run") end)

      :ok = Conversation.handle_postback(enroll_tap(signup.id), "rt-x", "Ustranger")
      :ok = Conversation.handle_postback(makeup_tap(makeup.id), "rt-y", "Ustranger")

      assert Repo.reload!(signup).state == "pending"
      assert Repo.reload!(makeup).state == "pending"
      unknown = Labels.t(:unknown_action, "zh-TW")

      assert [
               {:reply, {"rt-x", [%{text: ^unknown}]}},
               {:reply, {"rt-y", [%{text: ^unknown}]}}
             ] = LineMock.calls()
    end
  end
end
