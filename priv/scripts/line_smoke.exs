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
# dispatch, the agent loop, tool calls, draft creation, postback confirm and
# the retention sweep — is production code writing to the real dev DB.
#
# Rows created here are prefixed SMOKE / smoke- and deleted again at the end.

import Ecto.Query

alias Ganesha.{Catalog, Line, People, Repo, Sales}
alias Ganesha.Assistant
alias Ganesha.Assistant.{Draft, Message, ProcessEventWorker, PurgeGroupRawTextWorker, Thread}
alias Ganesha.Assistant.Provider.Mock, as: ProviderMock
alias Ganesha.Line.Client.Mock, as: LineMock
alias Ganesha.Line.{LineEvent, VerifySignaturePlug}

teacher_id = "Usmoketeacher000000000000000"
group_id = "Csmokegroup00000000000000000"
secret = "smoke_channel_secret"

# Only the PASS/FAIL lines matter here; Ecto's debug SQL would bury them.
Logger.configure(level: :warning)

Application.put_env(:ganesha, :assistant, provider: ProviderMock)
Application.put_env(:ganesha, :line_client, LineMock)

Application.put_env(:ganesha, :line,
  channel_secret: secret,
  channel_access_token: "smoke_token",
  teacher_line_user_id: teacher_id
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
  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  smoke_event_ids =
    Repo.all(from e in LineEvent, where: like(e.webhook_event_id, "smoke-%"), select: e.id)

  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))

  thread_ids = from(t in Thread, where: t.source_id in ^[teacher_id, group_id], select: t.id)
  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id in ^[teacher_id, group_id]))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(e in LineEvent, where: like(e.webhook_event_id, "smoke-%")))

  # Only the jobs this script's own events enqueued.
  Repo.delete_all(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.ProcessEventWorker",
      where: json_extract_path(j.args, ["line_event_id"]) in ^smoke_event_ids
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
Smoke.step(3, "teacher 1:1 turn: agent runs, tool creates a draft, reply carries quick replies")

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
    {:ok, %{text: "已建立一筆 3200 的付款草稿，請確認。", tool_calls: []}}
  else
    {:ok,
     %{
       text: nil,
       tool_calls: [
         %{
           id: "smoke-call-1",
           name: "propose_payment_draft",
           input: %{
             "student_id" => student.id,
             "purchase_id" => purchase.id,
             "amount" => 3200,
             "method" => "line_bank",
             "reported_last5" => "12345",
             "confidence" => 0.9
           }
         }
       ]
     }}
  end
end)

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
  "pending payment draft created",
  draft && draft.kind == "payment" && draft.state == "pending"
)

Smoke.check(
  "draft linked to the originating message",
  draft && draft.origin_message_id == hd(teacher_messages).id
)

calls = LineMock.calls()
reply_payload = Enum.find_value(calls, fn {:reply, {_token, msgs}} -> msgs end)
quick_reply = reply_payload && hd(reply_payload)[:quickReply]
labels = quick_reply && Enum.map(quick_reply.items, & &1.action.label)
postback_data = quick_reply && Enum.map(quick_reply.items, & &1.action.data)

Smoke.check("exactly one LINE reply sent to the teacher", length(calls) == 1)
Smoke.check("reply offers 確認 / 捨棄 quick replies", labels == ["確認", "捨棄"])

Smoke.check(
  "quick replies carry this draft's id",
  postback_data == ["action=confirm&draft_id=#{draft.id}", "action=discard&draft_id=#{draft.id}"]
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

replay = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => postback_line_event.id}})

payments_after =
  Repo.aggregate(from(p in Sales.Payment, where: p.purchase_id == ^purchase.id), :count)

Smoke.check(
  "replaying the same postback does not double-charge",
  replay == :ok and payments_after == 1
)

# ---------------------------------------------------------------- Step 6
Smoke.step(6, "24h retention sweep purges group raw text, keeps the teacher's")

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
