#!/usr/bin/env elixir
# Offline end-to-end smoke test for the LINE webhook + AI assistant.
#
#     mix ecto.migrate                        # once, applies the LINE tables to the dev DB
#     mix run priv/scripts/line_smoke.exs
#
# Needs no LINE channel, no Anthropic key and no network: the only two
# outbound edges (the LLM provider and the LINE Messaging API client) are
# swapped for the same in-process mocks the test suite uses. Everything
# between them — signature verification, webhook persistence, dedup, Oban
# dispatch, the Conversation, the agent loop over tasks, Draft creation, the
# Draft card, postback confirm and the retention sweep — is production code
# writing to the real dev DB.
#
# Rows created here are prefixed SMOKE / smoke- and deleted again at the end.

import Ecto.Query

alias Ganesha.{Catalog, Clock, Line, People, Repo, Roster, Sales, Studio}
alias Ganesha.Assistant

alias Ganesha.Assistant.{
  Digest,
  Draft,
  DraftNotifier,
  Message,
  ProcessEventWorker,
  PurgeGroupRawTextWorker,
  Thread
}

alias Ganesha.Assistant.Provider.Mock, as: ProviderMock
alias Ganesha.Line.Client.Mock, as: LineMock
alias Ganesha.Line.{LineEvent, VerifySignaturePlug}

teacher_id = "Usmoketeacher000000000000000"
group_id = "Csmokegroup00000000000000000"
blocked_sender_id = "Usmokeblocked0000000000000000"
newcomer_id = "Usmokenewcomer00000000000000000"
secret = "smoke_channel_secret"
smoke_sources = [teacher_id, group_id, newcomer_id]

# Only the PASS/FAIL lines matter here; Ecto's debug SQL would bury them.
Logger.configure(level: :warning)

Application.put_env(:ganesha, :assistant, provider: ProviderMock)
Application.put_env(:ganesha, :line_client, LineMock)

# Merged over the dev config so its other keys, purge_raw_text above all,
# survive. simple_reply is pinned off: dev defaults it on, and it would skip the
# agent turns this script exercises.
Application.put_env(
  :ganesha,
  :line,
  Keyword.merge(Application.get_env(:ganesha, :line, []),
    channel_secret: secret,
    channel_access_token: "smoke_token",
    teacher_line_user_ids: [teacher_id],
    simple_reply: false
  )
)

# Jobs must not run in a background queue process: the mocks live in this
# process's dictionary, and each step below runs the worker inline instead.
Oban.pause_all_queues()

defmodule Smoke do
  def init, do: Process.put(:smoke_failures, 0)

  def check(label, true), do: IO.puts([IO.ANSI.green(), "  PASS  ", IO.ANSI.reset(), label])

  def check(label, false) do
    Process.put(:smoke_failures, Process.get(:smoke_failures) + 1)
    IO.puts([IO.ANSI.red(), "  FAIL  ", IO.ANSI.reset(), label])
  end

  def check(label, other), do: check("#{label} (got: #{inspect(other)})", false)

  def step(n, title), do: IO.puts([IO.ANSI.bright(), "\nStep #{n}: #{title}", IO.ANSI.reset()])

  def failures, do: Process.get(:smoke_failures)
end

cleanup = fn ->
  smoke_thread_ids =
    Repo.all(from t in Thread, where: t.source_id in ^smoke_sources, select: t.id)

  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  smoke_event_ids =
    Repo.all(from e in LineEvent, where: like(e.webhook_event_id, "smoke-%"), select: e.id)

  smoke_slot_ids = from(s in Studio.Slot, where: like(s.label, "SMOKE%"), select: s.id)

  smoke_session_ids =
    from(s in Studio.Session, where: s.slot_id in subquery(smoke_slot_ids), select: s.id)

  # Credits point at Sessions, Students and Attendances: they go first.
  Repo.delete_all(
    from(c in Roster.Credit,
      where:
        c.origin_session_id in subquery(smoke_session_ids) or
          c.student_id in subquery(student_ids)
    )
  )

  Repo.delete_all(
    from(a in Roster.Attendance,
      where: a.session_id in subquery(smoke_session_ids) or a.student_id in subquery(student_ids)
    )
  )

  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))
  Repo.delete_all(from(s in Studio.Session, where: s.id in subquery(smoke_session_ids)))
  Repo.delete_all(from(s in Studio.Slot, where: like(s.label, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))

  thread_ids = from(t in Thread, where: t.source_id in ^smoke_sources, select: t.id)
  Repo.delete_all(from(d in Digest, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id in ^smoke_sources))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))

  Repo.delete_all(
    from(b in Line.BlockedAccount, where: b.line_id in ^[group_id, blocked_sender_id])
  )

  Repo.delete_all(from(e in LineEvent, where: like(e.webhook_event_id, "smoke-%")))

  # Only the jobs this script's own events enqueued.
  Repo.delete_all(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.ProcessEventWorker",
      where: json_extract_path(j.args, ["line_event_id"]) in ^smoke_event_ids
    )
  )

  Repo.delete_all(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.DraftNotifier",
      where: fragment("json_extract(?, '$.thread_id')", j.args) in ^smoke_thread_ids
    )
  )
end

Smoke.init()
cleanup.()

IO.puts([IO.ANSI.bright(), "LINE + AI assistant offline smoke test", IO.ANSI.reset()])

# ---------------------------------------------------------------- Step 1
Smoke.step(1, "webhook signature verification is fail-closed")

body = ~s({"events":[]})
valid_sig = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

conn = fn sig ->
  c =
    Plug.Test.conn(:post, "/line/webhook", body)
    |> Plug.Conn.assign(:raw_body, body)

  c = if sig, do: Plug.Conn.put_req_header(c, "x-line-signature", sig), else: c
  VerifySignaturePlug.call(c, [])
end

ok_conn = conn.(valid_sig)
Smoke.check("valid signature passes through", ok_conn.halted == false)

bad_conn = conn.(Base.encode64("wrong-signature-bytes-------"))
Smoke.check("forged signature -> 403 + halt", bad_conn.status == 403 and bad_conn.halted)

none_conn = conn.(nil)

Smoke.check(
  "missing signature header -> 403 + halt",
  none_conn.status == 403 and none_conn.halted
)

# ---------------------------------------------------------------- Step 2
Smoke.step(2, "webhook ingestion is idempotent and enqueues exactly once")

teacher_event = %{
  "webhookEventId" => "smoke-teacher-1",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-1",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-1", "type" => "text", "text" => "小美轉了 3200"}
}

jobs_before = Repo.aggregate(Oban.Job, :count)
:ok = Line.record_event(teacher_event)
:ok = Line.record_event(teacher_event)

stored = Repo.all(from e in LineEvent, where: e.webhook_event_id == "smoke-teacher-1")
Smoke.check("duplicate delivery stored exactly once", length(stored) == 1)
Smoke.check("teacher event source_id is the user", hd(stored).source_id == teacher_id)

jobs_after = Repo.aggregate(Oban.Job, :count)
Smoke.check("exactly one job enqueued for two deliveries", jobs_after - jobs_before == 1)

# ---------------------------------------------------------------- Step 3
Smoke.step(3, "teacher 1:1 turn: record_payment becomes a Draft, the reply carries its card")

{:ok, student} = People.create_student(%{display_name: "SMOKE 小美", active: true})

package =
  Repo.get_by(Catalog.Package, name: "月課程") ||
    (
      {:ok, p} =
        Catalog.create_package(%{
          name: "SMOKE 月課程",
          kind: "monthly",
          price_per_class: 400,
          included_makeups: 1
        })

      p
    )

{:ok, purchase} =
  Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 3200})

ProviderMock.stub(fn messages, _tools, _opts ->
  if Enum.any?(messages, &(&1.role == "tool")) do
    {:ok, %{text: "已建立一筆 3200 的收款草稿，請確認。", tool_calls: []}}
  else
    {:ok,
     %{
       text: nil,
       tool_calls: [
         %{
           id: "smoke-call-1",
           name: "record_payment",
           input: %{
             "student_id" => student.id,
             "purchase_id" => purchase.id,
             "amount" => 3200,
             "method" => "line_bank",
             "reported_last5" => "12345"
           }
         }
       ]
     }}
  end
end)

# A 1:1 thread without a locale gets the language picker instead of the agent;
# the teacher has already chosen hers.
{:ok, teacher_thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, _} = Assistant.set_locale(teacher_thread, "zh-TW")

teacher_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-1")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => teacher_line_event.id}})

teacher_thread = Repo.get_by!(Thread, source_type: "teacher", source_id: teacher_id)
teacher_messages = Assistant.list_messages(teacher_thread)

Smoke.check(
  "thread holds user + assistant + tool + final assistant turns",
  Enum.map(teacher_messages, & &1.role) == ["user", "assistant", "tool", "assistant"]
)

Smoke.check(
  "user message stamped with the LINE message id",
  hd(teacher_messages).line_message_id == "smoke-msg-1"
)

draft = Repo.one(from d in Draft, where: d.thread_id == ^teacher_thread.id)

Smoke.check(
  "pending record_payment draft created",
  draft && draft.kind == "record_payment" && draft.state == "pending"
)

Smoke.check(
  "draft linked to the originating message",
  draft && draft.origin_message_id == hd(teacher_messages).id
)

calls = LineMock.calls()
replies = for {:reply, {_token, messages}} <- calls, do: messages

Smoke.check(
  "loading animation shown before the reply",
  match?([{:loading, {^teacher_id, 20}} | _], calls)
)

Smoke.check("exactly one LINE reply sent to the teacher", length(replies) == 1)

carousel = replies |> List.first([]) |> Enum.find(&(&1[:type] == "flex"))
bubble = carousel && hd(carousel.contents.contents)

postback_data =
  bubble &&
    bubble.footer.contents
    |> Enum.map(& &1.action[:data])
    |> Enum.reject(&is_nil/1)

Smoke.check(
  "the reply carries this draft's card with 確認 / 捨棄",
  postback_data == ["action=confirm&draft_id=#{draft.id}", "action=discard&draft_id=#{draft.id}"]
)

summary = Assistant.draft_summary(draft, "zh-TW")

Smoke.check(
  "the card is one sentence naming the student and the amount",
  bubble != nil and match?([%{text: ^summary}], bubble.body.contents) and
    summary =~ "SMOKE 小美" and summary =~ "NT$3,200"
)

Smoke.check(
  "the model's reply records the card it sent",
  List.last(teacher_messages).content =~ "[草稿 ##{draft.id} 待確認] #{summary}"
)

Smoke.check("event marked processed", Repo.reload!(teacher_line_event).processed_at != nil)

# ---------------------------------------------------------------- Step 4
Smoke.step(4, "group turn is listen-only: history recorded, nothing sent back")

group_event = %{
  "webhookEventId" => "smoke-group-1",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-2",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => "Usmokestudent000"},
  "message" => %{"id" => "smoke-msg-2", "type" => "text", "text" => "我這週三要請假"}
}

:ok = Line.record_event(group_event)
group_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-1")

Smoke.check(
  "group event source_id is the group, not the sender",
  group_line_event.source_id == group_id
)

ProviderMock.stub(fn _messages, _tools, _opts ->
  {:ok, %{text: "（僅記錄，無需建立草稿）", tool_calls: []}}
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => group_line_event.id}})

group_thread = Repo.get_by!(Thread, source_type: "group", source_id: group_id)
group_messages = Assistant.list_messages(group_thread)

Smoke.check(
  "group message recorded in the group thread",
  Enum.any?(group_messages, &(&1.content == "我這週三要請假"))
)

Smoke.check("NOTHING sent to LINE from the group path", LineMock.calls() == [])

# ---------------------------------------------------------------- Step 5
Smoke.step(5, "teacher postback is the only path that confirms money")

postback_event = %{
  "webhookEventId" => "smoke-postback-1",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-3",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{"data" => "action=confirm&draft_id=#{draft.id}"}
}

:ok = Line.record_event(postback_event)
postback_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-1")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => postback_line_event.id}})

payment = Repo.one(from p in Sales.Payment, where: p.purchase_id == ^purchase.id)
Smoke.check("payment row created from the draft", payment != nil)
Smoke.check("payment is confirmed", payment && payment.state == "confirmed")

Smoke.check(
  "confirmed_by records the human LINE action",
  payment && payment.confirmed_by == "line:teacher"
)

Smoke.check("payment tagged as draft-sourced", payment && payment.source == "line_draft")

Smoke.check(
  "amount and method came from the draft",
  payment && payment.amount == 3200 && payment.method == "line_bank"
)

applied = Repo.reload!(draft)
Smoke.check("draft marked applied", applied.state == "applied")

Smoke.check(
  "draft points at the payment row",
  applied.applied_record_type == "Ganesha.Sales.Payment" and
    applied.applied_record_id == payment.id
)

outcome_texts = for {:reply, {_token, [message]}} <- LineMock.calls(), do: message.text

Smoke.check(
  "the teacher is told what was confirmed",
  outcome_texts == [Line.Labels.t(:confirmed, "zh-TW", title: summary)]
)

Smoke.check(
  "the outcome is in the model's history",
  List.last(Assistant.list_messages(teacher_thread)).content ==
    "[已確認] 草稿 ##{draft.id} #{summary}"
)

replay = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => postback_line_event.id}})

payments_after =
  Repo.aggregate(from(p in Sales.Payment, where: p.purchase_id == ^purchase.id), :count)

Smoke.check(
  "replaying the same postback does not double-charge",
  replay == :ok and payments_after == 1
)

# ---------------------------------------------------------------- Step 6
Smoke.step(6, "24h retention sweep purges group raw text, keeps the teacher's")

# The purge is unscoped: in dev, where raw text is kept on purpose, running it
# would wipe every real group message older than 24h, not just the smoke rows.
if Keyword.get(Application.fetch_env!(:ganesha, :line), :purge_raw_text, true) do
  old = DateTime.utc_now() |> DateTime.add(-25 * 3600, :second) |> DateTime.truncate(:second)

  Repo.update_all(from(e in LineEvent, where: e.webhook_event_id == "smoke-group-1"),
    set: [inserted_at: old]
  )

  Repo.update_all(from(e in LineEvent, where: e.webhook_event_id == "smoke-teacher-1"),
    set: [inserted_at: old]
  )

  Repo.update_all(from(m in Message, where: m.thread_id == ^group_thread.id),
    set: [inserted_at: old]
  )

  Repo.update_all(from(m in Message, where: m.thread_id == ^teacher_thread.id),
    set: [inserted_at: old]
  )

  :ok = PurgeGroupRawTextWorker.perform(%Oban.Job{})

  Smoke.check(
    "group event payload purged",
    Repo.reload!(group_line_event).payload == %{"purged" => true}
  )

  Smoke.check(
    "group message text nulled",
    Repo.all(from m in Message, where: m.thread_id == ^group_thread.id, select: m.content)
    |> Enum.all?(&is_nil/1)
  )

  Smoke.check(
    "teacher event payload retained",
    Repo.reload!(teacher_line_event).payload["webhookEventId"] == "smoke-teacher-1"
  )

  Smoke.check(
    "teacher thread text retained",
    Repo.all(
      from m in Message,
        where: m.thread_id == ^teacher_thread.id and m.role == "user",
        select: m.content
    ) == ["小美轉了 3200"]
  )

  Smoke.check(
    "confirmed draft's parsed data retained",
    Repo.reload!(draft).parsed["amount"] == 3200
  )
else
  IO.puts([
    IO.ANSI.yellow(),
    "  SKIP  ",
    IO.ANSI.reset(),
    "Step 6 skipped: dev keeps raw text (purge_raw_text: false)"
  ])
end

# ---------------------------------------------------------------- Step 7
Smoke.step(7, "teacher question: next_session is answered in text only")

today = Clock.today()
weekday = Date.day_of_week(today)
taken = Repo.all(from s in Studio.Slot, where: s.weekday == ^weekday, select: s.start_time)

# Slots are unique on weekday + start_time. Today's earliest free time also
# makes this SMOKE Session the next one Studio.next_session/0 finds.
start_time =
  0..287
  |> Enum.map(&Time.add(~T[00:00:00], &1 * 5 * 60))
  |> Enum.find(&(&1 not in taken))

{:ok, smoke_slot} =
  Studio.create_slot(%{
    weekday: weekday,
    start_time: start_time,
    end_time: Time.add(start_time, 60 * 60),
    default_style: "Hatha",
    label: "SMOKE 基礎"
  })

{:ok, smoke_session} =
  Studio.create_session(%{slot_id: smoke_slot.id, date: today, style: "Hatha"})

{:ok, _} = Roster.enroll(smoke_session, student, purchase)

question_event = %{
  "webhookEventId" => "smoke-teacher-2",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-4",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-3", "type" => "text", "text" => "下一堂課誰會來？"}
}

:ok = Line.record_event(question_event)
question_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-2")

# The thread already holds Step 3's tool round, so only the latest message
# tells whether next_session has been answered.
ProviderMock.stub(fn messages, _tools, _opts ->
  case List.last(messages) do
    %{role: "tool"} ->
      {:ok, %{text: "今天有一堂，SMOKE 小美會來。", tool_calls: []}}

    _ ->
      {:ok, %{text: nil, tool_calls: [%{id: "smoke-call-2", name: "next_session", input: %{}}]}}
  end
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => question_line_event.id}})

question_replies = for {:reply, {"smoke-reply-4", messages}} <- LineMock.calls(), do: messages
Smoke.check("exactly one LINE reply sent to the question", length(question_replies) == 1)

Smoke.check(
  "the answer to a question is text only",
  question_replies |> List.first([]) |> Enum.all?(&(&1.type == "text"))
)

next_session_result =
  teacher_thread
  |> Assistant.list_messages()
  |> Enum.filter(&(&1.role == "tool"))
  |> List.last()
  |> Map.fetch!(:tool_calls)
  |> hd()
  |> Map.fetch!("content")

Smoke.check(
  "the model is told the SMOKE session and who is coming",
  next_session_result =~ Assistant.Format.session_day(today, "zh-TW") and
    next_session_result =~ "SMOKE 基礎" and next_session_result =~ "SMOKE 小美"
)

Smoke.check(
  "the model's reply is recorded as sent, with no card lines",
  List.last(Assistant.list_messages(teacher_thread)).content == "今天有一堂，SMOKE 小美會來。"
)

Smoke.check(
  "question event marked processed",
  Repo.reload!(question_line_event).processed_at != nil
)

# ---------------------------------------------------------------- Step 8
Smoke.step(8, "teacher cancels a session: Draft card, Confirm cancels it and issues a Credit")

cancel_start =
  0..287
  |> Enum.map(&Time.add(~T[00:00:00], &1 * 5 * 60))
  |> Enum.find(&(&1 not in [start_time | taken]))

{:ok, cancel_slot} =
  Studio.create_slot(%{
    weekday: weekday,
    start_time: cancel_start,
    end_time: Time.add(cancel_start, 60 * 60),
    default_style: "Hatha",
    label: "SMOKE 停課"
  })

cancel_date = Date.add(today, 7)

{:ok, cancel_session} =
  Studio.create_session(%{slot_id: cancel_slot.id, date: cancel_date, style: "Hatha"})

{:ok, _} = Roster.enroll(cancel_session, student, purchase)

cancel_event = %{
  "webhookEventId" => "smoke-teacher-3",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-5",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-4", "type" => "text", "text" => "下週那堂停課，颱風假"}
}

:ok = Line.record_event(cancel_event)
cancel_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-3")

ProviderMock.stub(fn messages, _tools, _opts ->
  case List.last(messages) do
    %{role: "tool"} ->
      {:ok, %{text: "已建立停課草稿，請確認。", tool_calls: []}}

    _ ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-3",
             name: "cancel_session",
             input: %{"session_id" => cancel_session.id, "reason" => "颱風假"}
           }
         ]
       }}
  end
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => cancel_line_event.id}})

cancel_draft =
  Repo.one(
    from d in Draft,
      where: d.thread_id == ^teacher_thread.id and d.kind == "cancel_session"
  )

Smoke.check(
  "pending cancel_session draft created for the SMOKE session",
  cancel_draft != nil and cancel_draft.state == "pending" and
    cancel_draft.parsed["session_id"] == cancel_session.id and
    cancel_draft.parsed["credit_count"] == 1
)

cancel_replies = for {:reply, {"smoke-reply-5", messages}} <- LineMock.calls(), do: messages
cancel_carousel = cancel_replies |> List.first([]) |> Enum.find(&(&1[:type] == "flex"))

cancel_postbacks =
  case cancel_carousel do
    %{contents: %{contents: [bubble | _]}} ->
      bubble.footer.contents |> Enum.map(& &1.action[:data]) |> Enum.reject(&is_nil/1)

    _ ->
      nil
  end

Smoke.check(
  "the reply carries the cancel draft's card with 確認 / 捨棄",
  cancel_draft != nil and
    cancel_postbacks == [
      "action=confirm&draft_id=#{cancel_draft.id}",
      "action=discard&draft_id=#{cancel_draft.id}"
    ]
)

Smoke.check(
  "the session is still scheduled before Confirm",
  Studio.get_session!(cancel_session.id).state == "scheduled"
)

cancel_postback_event = %{
  "webhookEventId" => "smoke-postback-2",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-6",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{"data" => "action=confirm&draft_id=#{cancel_draft && cancel_draft.id}"}
}

:ok = Line.record_event(cancel_postback_event)
cancel_postback_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-2")
Process.delete(:line_client_mock_calls)

:ok =
  ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => cancel_postback_line_event.id}})

cancelled = Studio.get_session!(cancel_session.id)

Smoke.check(
  "Confirm cancels the session with the stated reason",
  cancelled.state == "cancelled" and cancelled.cancel_reason == "颱風假"
)

cancel_credits =
  Repo.all(from c in Roster.Credit, where: c.origin_session_id == ^cancel_session.id)

Smoke.check(
  "the enrolled student gets one cancellation Credit",
  match?([%{student_id: id, source: "cancellation"}] when id == student.id, cancel_credits)
)

applied_cancel = cancel_draft && Repo.reload!(cancel_draft)

Smoke.check(
  "the cancel draft is applied and points at the session",
  applied_cancel != nil and applied_cancel.state == "applied" and
    applied_cancel.applied_record_type == "Ganesha.Studio.Session" and
    applied_cancel.applied_record_id == cancel_session.id
)

Smoke.check(
  "the teacher is told the outcome",
  length(for {:reply, {"smoke-reply-6", _}} <- LineMock.calls(), do: :ok) == 1
)

# ---------------------------------------------------------------- Step 9
Smoke.step(9, "teacher enroll: Draft card, Confirm creates purchase and attendances")

{:ok, enroll_student} = People.create_student(%{display_name: "SMOKE 阿花", active: true})

enroll_weekday = 5

enroll_taken =
  Repo.all(from s in Studio.Slot, where: s.weekday == ^enroll_weekday, select: s.start_time)

enroll_start =
  0..287
  |> Enum.map(&Time.add(~T[00:00:00], &1 * 5 * 60))
  |> Enum.find(&(&1 not in enroll_taken))

{:ok, enroll_slot} =
  Studio.create_slot(%{
    weekday: enroll_weekday,
    start_time: enroll_start,
    end_time: Time.add(enroll_start, 60 * 60),
    default_style: "Hatha",
    label: "SMOKE 月課"
  })

{:ok, enroll_sessions} = Studio.generate_month(enroll_slot, ~D[2026-10-01])

{:ok, enroll_package} =
  Catalog.create_package(%{
    name: "SMOKE 月課報名",
    kind: "monthly",
    price_per_class: 400,
    included_makeups: 1
  })

enroll_event = %{
  "webhookEventId" => "smoke-teacher-4",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-7",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-5", "type" => "text", "text" => "幫阿花報名十月月課"}
}

:ok = Line.record_event(enroll_event)
enroll_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-4")

ProviderMock.stub(fn messages, _tools, _opts ->
  case List.last(messages) do
    %{role: "tool"} ->
      {:ok, %{text: "已建立報名草稿，請確認。", tool_calls: []}}

    _ ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-4",
             name: "enroll",
             input: %{
               "student_id" => enroll_student.id,
               "slot_id" => enroll_slot.id,
               "month" => "2026-10",
               "package_id" => enroll_package.id
             }
           }
         ]
       }}
  end
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => enroll_line_event.id}})

enroll_draft =
  Repo.one(
    from d in Draft,
      where: d.thread_id == ^teacher_thread.id and d.kind == "enroll"
  )

Smoke.check(
  "pending enroll draft created for SMOKE 阿花",
  enroll_draft != nil and enroll_draft.state == "pending" and
    enroll_draft.student_id == enroll_student.id and
    enroll_draft.parsed["slot_id"] == enroll_slot.id
)

enroll_postback_event = %{
  "webhookEventId" => "smoke-postback-3",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-8",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{"data" => "action=confirm&draft_id=#{enroll_draft && enroll_draft.id}"}
}

:ok = Line.record_event(enroll_postback_event)
enroll_postback_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-3")
Process.delete(:line_client_mock_calls)

:ok =
  ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => enroll_postback_line_event.id}})

enroll_purchase =
  Repo.one(
    from p in Sales.Purchase,
      where: p.student_id == ^enroll_student.id and p.package_id == ^enroll_package.id
  )

enroll_attendance_count =
  Repo.aggregate(
    from(a in Roster.Attendance,
      where:
        a.student_id == ^enroll_student.id and a.session_id in ^Enum.map(enroll_sessions, & &1.id)
    ),
    :count
  )

applied_enroll = enroll_draft && Repo.reload!(enroll_draft)

Smoke.check(
  "Confirm creates the monthly purchase",
  enroll_purchase != nil and Sales.payable(enroll_purchase) > 0
)

Smoke.check(
  "Confirm books every October session for the slot",
  enroll_attendance_count == length(enroll_sessions)
)

Smoke.check(
  "the enroll draft is applied",
  applied_enroll != nil and applied_enroll.state == "applied" and
    applied_enroll.applied_record_type == "Ganesha.Sales.Purchase"
)

# ---------------------------------------------------------------- Step 10
Smoke.step(10, "group payment draft: notifier push, then teacher confirms")

group_pay_event = %{
  "webhookEventId" => "smoke-group-2",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-9",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => "Usmokestudent000"},
  "message" => %{"id" => "smoke-msg-6", "type" => "text", "text" => "2.SMOKE 小美 Line pay 3200"}
}

:ok = Line.record_event(group_pay_event)
group_pay_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-2")

ProviderMock.stub(fn messages, _tools, _opts ->
  case List.last(messages) do
    %{role: "tool"} ->
      {:ok, %{text: "已建立收款草稿。", tool_calls: []}}

    _ ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-5",
             name: "record_payment",
             input: %{
               "student_id" => student.id,
               "purchase_id" => purchase.id,
               "amount" => 3200,
               "method" => "line_pay"
             }
           }
         ]
       }}
  end
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => group_pay_line_event.id}})

group_payment_draft =
  Repo.one(
    from d in Draft,
      join: t in Thread,
      on: d.thread_id == t.id,
      where: t.source_id == ^group_id and d.kind == "record_payment" and d.state == "pending"
  )

group_thread = Assistant.get_group_thread(group_id)

notifier_jobs =
  Repo.aggregate(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.DraftNotifier",
      where: fragment("json_extract(?, '$.thread_id')", j.args) == ^group_thread.id
    ),
    :count
  )

Smoke.check("group payment creates a pending draft", group_payment_draft != nil)
Smoke.check("DraftNotifier job enqueued for the group", notifier_jobs == 1)

Process.delete(:line_client_mock_calls)
:ok = DraftNotifier.perform(%Oban.Job{args: %{"thread_id" => group_thread.id}})

notified_draft = group_payment_draft && Repo.reload!(group_payment_draft)

Smoke.check(
  "notifier push reaches the teacher",
  Enum.any?(LineMock.calls(), fn {:push, {to, _}} -> to == teacher_id end)
)

Smoke.check(
  "notifier sets notified_at on the group draft",
  notified_draft != nil and notified_draft.notified_at != nil
)

group_confirm_event = %{
  "webhookEventId" => "smoke-postback-4",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-10",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{
    "data" => "action=confirm&draft_id=#{group_payment_draft && group_payment_draft.id}"
  }
}

:ok = Line.record_event(group_confirm_event)
group_confirm_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-4")
Process.delete(:line_client_mock_calls)

:ok =
  ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => group_confirm_line_event.id}})

applied_group_payment = group_payment_draft && Repo.reload!(group_payment_draft)

Smoke.check(
  "teacher Confirm applies the group-originated payment draft",
  applied_group_payment != nil and applied_group_payment.state == "applied" and
    applied_group_payment.applied_record_type == "Ganesha.Sales.Payment"
)

# ---------------------------------------------------------------- Step 11
Smoke.step(11, "teacher blocks a group sender; their next message is ignored")

seen_event = %{
  "webhookEventId" => "smoke-group-3",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-11",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => blocked_sender_id},
  "message" => %{"id" => "smoke-msg-7", "type" => "text", "text" => "大家早安"}
}

:ok = Line.record_event(seen_event)
seen_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-3")

Smoke.check(
  "group event stored without its reply token",
  not Map.has_key?(seen_line_event.payload, "replyToken")
)

ProviderMock.stub(fn _messages, _tools, _opts ->
  {:ok, %{text: "nothing to do", tool_calls: []}}
end)

:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => seen_line_event.id}})

Smoke.check(
  "group message stored with its sender",
  Repo.exists?(
    from m in Message,
      where: m.line_message_id == "smoke-msg-7" and m.sender_id == ^blocked_sender_id
  )
)

block_event = %{
  "webhookEventId" => "smoke-teacher-5",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-12",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-8", "type" => "text", "text" => "封鎖 測試學生"}
}

:ok = Line.record_event(block_event)
block_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-5")

ProviderMock.stub(fn messages, _tools, _opts ->
  case List.last(messages) do
    %{role: "tool"} ->
      {:ok, %{text: "封鎖草稿等你確認。", tool_calls: []}}

    _ ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-6",
             name: "block_account",
             input: %{"kind" => "sender", "line_id" => blocked_sender_id}
           }
         ]
       }}
  end
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => block_line_event.id}})

block_draft =
  Repo.one(
    from d in Draft,
      join: t in Thread,
      on: d.thread_id == t.id,
      where: t.source_id == ^teacher_id and d.kind == "block_account" and d.state == "pending"
  )

Smoke.check("Teacher chat proposes a block_account draft", block_draft != nil)

block_confirm_event = %{
  "webhookEventId" => "smoke-postback-5",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-13",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{"data" => "action=confirm&draft_id=#{block_draft && block_draft.id}"}
}

:ok = Line.record_event(block_confirm_event)
block_confirm_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-5")
Process.delete(:line_client_mock_calls)

:ok =
  ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => block_confirm_line_event.id}})

Smoke.check("Confirm blocks the sender", Line.blocked?("sender", blocked_sender_id))

blocked_event = %{
  "webhookEventId" => "smoke-group-4",
  "mode" => "active",
  "type" => "message",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => blocked_sender_id},
  "message" => %{"id" => "smoke-msg-9", "type" => "text", "text" => "2.SMOKE 小美 Line pay 3200"}
}

:ok = Line.record_event(blocked_event)
blocked_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-4")

ProviderMock.stub(fn _messages, _tools, _opts ->
  Process.put(:smoke_blocked_agent_ran, true)
  {:ok, %{text: "should not run", tool_calls: []}}
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => blocked_line_event.id}})

Smoke.check(
  "blocked sender's message never reaches the agent",
  Process.get(:smoke_blocked_agent_ran) != true
)

Smoke.check(
  "blocked sender's message is not stored in the group thread",
  not Repo.exists?(from m in Message, where: m.line_message_id == "smoke-msg-9")
)

Smoke.check("NOTHING sent to LINE for the blocked message", LineMock.calls() == [])

# ---------------------------------------------------------------- Step 12
Smoke.step(12, "a newcomer asks to sign up; the teacher gets the card and taps 幫他報名")

{:ok, newcomer_thread} = Assistant.get_or_create_thread("user", newcomer_id)
{:ok, _} = Assistant.set_locale(newcomer_thread, "zh-TW")
Process.put(:line_client_mock_profile, {:ok, %{"displayName" => "SMOKE 新朋友"}})

# The Student chat proposes signup_request; the Teacher chat proposes add_student.
ProviderMock.stub(fn messages, tools, _opts ->
  student_chat? = "signup_request" in Enum.map(tools, & &1.name)

  case {List.last(messages), student_chat?} do
    {%{role: "tool"}, true} ->
      {:ok, %{text: "老師會親自回覆你喔！", tool_calls: []}}

    {%{role: "tool"}, false} ->
      {:ok, %{text: "先新增這位學生，確認後跟我說「繼續」。", tool_calls: []}}

    {_, true} ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-8",
             name: "signup_request",
             input: %{"note" => "想報名週一晚上的課，11月開始"}
           }
         ]
       }}

    {_, false} ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-9",
             name: "add_student",
             input: %{"display_name" => "SMOKE 新朋友", "line_user_id" => newcomer_id}
           }
         ]
       }}
  end
end)

signup_event = %{
  "webhookEventId" => "smoke-newcomer-1",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-12",
  "source" => %{"type" => "user", "userId" => newcomer_id},
  "message" => %{"id" => "smoke-msg-10", "type" => "text", "text" => "我想報名週一晚上的課，11月開始"}
}

:ok = Line.record_event(signup_event)
signup_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-newcomer-1")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => signup_line_event.id}})

signup_draft =
  Repo.one(
    from d in Draft,
      where:
        d.thread_id == ^newcomer_thread.id and d.kind == "signup_request" and
          d.state == "pending"
  )

Smoke.check("the newcomer's sign-up request is a pending draft", signup_draft != nil)

Smoke.check(
  "the newcomer gets text only, no card",
  match?(
    [{:loading, _}, {:reply, {"smoke-reply-12", [%{type: "text"}]}}],
    LineMock.calls()
  )
)

newcomer_jobs =
  Repo.aggregate(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.DraftNotifier",
      where: fragment("json_extract(?, '$.thread_id')", j.args) == ^newcomer_thread.id
    ),
    :count
  )

Smoke.check("a DraftNotifier job waits for the newcomer's chat", newcomer_jobs == 1)

Process.delete(:line_client_mock_calls)
:ok = DraftNotifier.perform(%Oban.Job{args: %{"thread_id" => newcomer_thread.id}})

Smoke.check(
  "the sign-up card is pushed to the teacher",
  Enum.any?(LineMock.calls(), fn
    {:push, {to, _}} -> to == teacher_id
    _ -> false
  end)
)

enroll_tap_event = %{
  "webhookEventId" => "smoke-postback-6",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-13",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{
    "data" => "action=enroll_from_request&draft_id=#{signup_draft && signup_draft.id}"
  }
}

:ok = Line.record_event(enroll_tap_event)
enroll_tap_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-6")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => enroll_tap_line_event.id}})

Smoke.check(
  "幫他報名 marks the request handled",
  signup_draft != nil and Repo.reload!(signup_draft).state == "applied"
)

add_student_draft =
  Repo.one(
    from d in Draft,
      join: t in Thread,
      on: d.thread_id == t.id,
      where: t.source_id == ^teacher_id and d.kind == "add_student" and d.state == "pending"
  )

Smoke.check(
  "the teacher's turn proposes add_student linked to the newcomer's LINE ID",
  add_student_draft != nil and add_student_draft.parsed["line_user_id"] == newcomer_id
)

# ---------------------------------------------------------------- Step 13
Smoke.step(13, "a group sender asks to sign up; the teacher gets the card and taps 幫他報名")

group_joiner_id = "Usmokegroupjoiner00000000000000"
Process.put(:line_client_mock_group_member, {:ok, %{"displayName" => "SMOKE 群組新朋友"}})

# The Group chat proposes signup_request; the Teacher chat (the only one with
# enroll) proposes add_student for the sender's LINE ID.
ProviderMock.stub(fn messages, tools, _opts ->
  teacher_chat? = "enroll" in Enum.map(tools, & &1.name)

  case {List.last(messages), teacher_chat?} do
    {%{role: "tool"}, false} ->
      {:ok, %{text: "已記錄報名申請。", tool_calls: []}}

    {%{role: "tool"}, true} ->
      {:ok, %{text: "先新增這位學生，確認後跟我說「繼續」。", tool_calls: []}}

    {_, false} ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{id: "smoke-call-10", name: "signup_request", input: %{"note" => "我想報名週一早上的課"}}
         ]
       }}

    {_, true} ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-11",
             name: "add_student",
             input: %{"display_name" => "SMOKE 群組新朋友", "line_user_id" => group_joiner_id}
           }
         ]
       }}
  end
end)

group_signup_event = %{
  "webhookEventId" => "smoke-group-5",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-14",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => group_joiner_id},
  "message" => %{"id" => "smoke-msg-11", "type" => "text", "text" => "我想報名週一早上的課"}
}

:ok = Line.record_event(group_signup_event)
group_signup_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-5")
Process.delete(:line_client_mock_calls)

:ok =
  ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => group_signup_line_event.id}})

group_thread = Assistant.get_group_thread(group_id)

group_signup_draft =
  Repo.one(
    from d in Draft,
      where:
        d.thread_id == ^group_thread.id and d.kind == "signup_request" and d.state == "pending"
  )

Smoke.check(
  "the group sender's sign-up request is a pending draft for that sender",
  group_signup_draft != nil and group_signup_draft.parsed["line_user_id"] == group_joiner_id and
    group_signup_draft.parsed["line_name"] == "SMOKE 群組新朋友"
)

Smoke.check("NOTHING sent to LINE from the group sign-up", LineMock.calls() == [])

Process.delete(:line_client_mock_calls)
:ok = DraftNotifier.perform(%Oban.Job{args: %{"thread_id" => group_thread.id}})

Smoke.check(
  "the group sign-up card is pushed to the teacher",
  Enum.any?(LineMock.calls(), fn
    {:push, {to, _}} -> to == teacher_id
    _ -> false
  end)
)

group_tap_event = %{
  "webhookEventId" => "smoke-postback-7",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-15",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{
    "data" => "action=enroll_from_request&draft_id=#{group_signup_draft && group_signup_draft.id}"
  }
}

:ok = Line.record_event(group_tap_event)
group_tap_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-7")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => group_tap_line_event.id}})

Smoke.check(
  "幫他報名 marks the group request handled",
  group_signup_draft != nil and Repo.reload!(group_signup_draft).state == "applied"
)

group_add_student_draft =
  Repo.one(
    from d in Draft,
      join: t in Thread,
      on: d.thread_id == t.id,
      where: t.source_id == ^teacher_id and d.kind == "add_student" and d.state == "pending",
      where: fragment("json_extract(?, '$.line_user_id')", d.parsed) == ^group_joiner_id
  )

Smoke.check(
  "the teacher's turn proposes add_student linked to the group sender's LINE ID",
  group_add_student_draft != nil
)

# ---------------------------------------------------------------- teardown
cleanup.()
Oban.resume_all_queues()

IO.puts("")

case Smoke.failures() do
  0 ->
    IO.puts([
      IO.ANSI.green(),
      "ALL CHECKS PASSED",
      IO.ANSI.reset(),
      " — dev rows cleaned up, Oban queues resumed"
    ])

  n ->
    IO.puts([IO.ANSI.red(), "#{n} CHECK(S) FAILED", IO.ANSI.reset()])
    System.halt(1)
end
