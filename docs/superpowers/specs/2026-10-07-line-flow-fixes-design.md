# LINE assistant: request flows and delivery fixes

Amends `2026-10-06-student-signup-request-design.md` (§5, decisions 6–7, the
out-of-scope bullet "running the next turn automatically after `add_student`")
and `2026-10-02-line-teacher-assistant-design.md` (§3.1 #18, #21, §6.1, §7).
Everything else in those specs stands.

## Problem

A gap review on 2026-10-07 found these, in order of harm:

1. **Sign-up requests close before anything is booked.** 「幫他報名」 confirms
   the `signup_request` Draft first, then starts a teacher turn. A newcomer
   then needs `add_student` → Confirm → 「繼續」 → `enroll` → Confirm, in that
   order, with only the prompt enforcing it. If the turn fails, she discards the
   `enroll` card, or she never says 「繼續」, the request is already "applied"
   and nothing records that nobody was enrolled.
2. **確認 on a request card books nothing.** On `signup_request` and
   `makeup_request` cards, 確認 reads as "done" but only acknowledges. The
   makeup request has no shortcut at all; `book_makeup` is unrelated to it.
3. **Events for one chat run concurrently.** `ProcessEventWorker` runs in
   `queue: [default: 5]` with no per-chat ordering. Two quick messages run two
   agent turns at once, interleave history and replies, and
   `Assistant.create_draft/3` stamps whichever user message is newest as
   `origin_message_id` (the group `signup_request` takes its asker from it too).
4. **A webhook row can be stored and never processed.** `Line.record_event/1`
   inserts the row, then enqueues outside any transaction; an enqueue failure is
   logged only. A failed insert still answers 200, so LINE never redelivers.
5. **An edited 1:1 message re-runs the agent and sends nothing.** The re-run
   turn's text and cards are stored but never reach LINE.
6. **Non-text 1:1 messages get no answer.** A student's payment screenshot or
   sticker is silently dropped.
7. **Anthropic calls use Req defaults.** 15 s receive timeout and no retry on
   429/5xx for POST, so a long turn or a brief overload becomes an apology.
8. **`confirm_payment` cannot be used.** Its tool says to take `payment_id`
   from the snapshot or `student_summary`; neither shows payment ids.
9. **Confirmations are not attributable.** Every LINE confirm passes
   `"line:teacher"` as `confirmed_by`, so with several teachers nobody can tell
   who confirmed a payment.

## Decisions

1. **A request Draft is settled by the Draft that acts on it.** `enroll` and
   `book_makeup` take an optional request id. Their `apply/2` claims that
   request (pending → applied, pointing at the new record) in the same
   transaction as the booking. Tapping 「幫他報名」 / 「幫他補課」 no longer
   touches the request.
2. **A newcomer is added and enrolled in one Draft.** `enroll` with a
   `signup_request_id` may name a `new_student_name` instead of a
   `student_id`; `apply/2` creates the student with the request's LINE user id,
   then enrolls. An existing student picked from the snapshot gets the
   request's LINE user id linked when they have none.
3. **確認 on request cards is relabelled 「已處理」 / "Handled".** It still only
   acknowledges, for requests the teacher settled outside LINE.
4. **One chat's events run in webhook order.** Before routing, a job whose
   chat has an earlier unprocessed event younger than 10 minutes snoozes for 1 s.
   One machine owns the SQLite file (`fly.toml`), so the database is the
   ordering authority; no lock is needed.
5. **Store and enqueue are one transaction.** A failed insert answers 500.
6. Edited 1:1 messages re-run through `Conversation.handle_message/3`, which
   pushes when there is no reply token.
7. Non-text 1:1 messages get one text reply: the bot reads text only.
8. Anthropic: `receive_timeout: 60_000`, `retry: :transient`, `max_retries: 2`.
   Re-sending a completion has no side effects.
9. `student_summary` lists the student's claimed payments with their ids.
10. LINE confirms pass `"line:<teacher LINE user id>"` as `confirmed_by`.

## 1. Request claims

`Ganesha.Assistant.claim_request(kind, id, {record_type, record_id})`:

- Runs inside the caller's transaction (`confirm_draft/2` already wraps
  `apply/2`).
- Compare-and-set `state == "pending" and kind == ^kind` → `applied`,
  `applied_record_type`/`applied_record_id` set to the new record.
- Returns `:ok`, or `{:error, :request_already_handled}` when 0 rows changed;
  the caller returns that error and the whole confirm rolls back (the acting
  Draft is marked failed with that reason).
- `Labels.failure_reason/2` gets `:request_already_handled`:
  「這個申請已經處理過了」 / "This request was already handled".

Propose-time checks (returned to the model): the request id must name a
pending Draft of the right kind.

## 2. `enroll` with a sign-up request

New optional inputs: `signup_request_id` (integer), `new_student_name`
(string). Rules in `propose/2`:

| inputs | student |
|---|---|
| `student_id` | that student (as today); with a request, the request's `line_user_id` is linked on apply if the student has none and no other student holds it; a student already linked to a different LINE id is an error |
| no `student_id`, request's LINE id linked | the linked student |
| no `student_id`, `new_student_name`, request unlinked | new student, `display_name` = trimmed name, `line_user_id` = request's |
| `new_student_name` without a request | error: needs `signup_request_id` |
| neither | error: needs `student_id` or `new_student_name` |

`parsed` adds `"signup_request_id"`, `"new_student"` (`%{"display_name",
"line_user_id"}` or nil) and `"link_line_user_id"` (or nil). For a new
student, the active/available/not-booked checks that need a student are
skipped; the package must be available to anyone.

`apply/2`, in order: claim the request (if any); resolve the student — a new
student whose LINE id got linked meanwhile → `{:error, :line_user_id_taken}`;
create or link; then the existing re-checks and `Enrolling.enroll_month/1`.
The claim records the Purchase.

Summary prefix for a new student: 「新增學生 小美 並」 / "Add new student 小美 and ".

## 3. `book_makeup` with a makeup request

New optional input `makeup_request_id`. Propose checks it is a pending
`makeup_request`; `parsed["makeup_request_id"]`. `apply/2` claims it after
the existing re-checks, recording the Attendance.

## 4. Cards and postbacks

`Cards.draft_bubble/2`:

| kind | buttons |
|---|---|
| `signup_request` | 幫他報名 (`action=enroll_from_request`), 已處理 (`action=confirm`), 捨棄 |
| `makeup_request` | 幫他補課 (`action=book_from_request`), 已處理 (`action=confirm`), 捨棄 |
| others | unchanged |

`Conversation.handle_postback/3`, `enroll_from_request` and new
`book_from_request`: teacher only; the Draft must exist, be of that kind and
pending (else the usual outcome text); append the request's teacher message as
a `user` message; run `handle_message/3`. Nothing is confirmed.

`SignupRequest.teacher_message/3` tells the model: propose `enroll` with
`signup_request_id` N; for an unlinked LINE id, match the snapshot first and
pass `student_id` if one fits, else `new_student_name` (LINE display name
unless she says otherwise); `ask_teacher` only when the match is unclear.
`MakeupRequest.teacher_message/3` (new) says: propose `book_makeup` with
`makeup_request_id` N, choosing session and credit from the snapshot /
`open_credits`. Student words stay quoted as today.

Teacher prompt rules for 「[報名申請 #N]」 and new 「[補課申請 #N]」 /
"[Makeup request #N]" follow the same text. The 「繼續」 instruction is removed.

### Edge cases

- Two teachers tap: both may get an acting Draft; the second confirm fails
  `:request_already_handled`.
- She discards the acting card or the turn fails: the request stays pending;
  she can tap again.
- She taps 已處理 after an acting Draft exists: the request is applied; the
  acting Draft's confirm then fails `:request_already_handled`.

## 5. Event ordering and storage

`ProcessEventWorker.perform/1`, before `route/1`:

```
earlier? = exists line_events where source_id == ^source_id and id < ^id
           and is_nil(processed_at) and inserted_at > ^(now - 600 s)
if earlier?, do: {:snooze, 1}
```

Events with a nil `source_id` skip the check. An event older than 10 minutes
that never processed stops holding its chat back.

`Line.record_event/1` inserts the row and, for active mode, the Oban job in one
`Repo.transaction`. Duplicate `webhookEventId` stays `:ok`. Any other failure
returns `{:error, reason}`; `LineWebhookController.create/2` answers 500 if
any event failed, else 200.

## 6. Delivery fixes

- `Conversation.deliver(nil, source_id, messages, fallback)` pushes directly.
- `ProcessEventWorker` re-runs an edited Teacher/Student chat message with
  `Conversation.handle_message(thread, payload["replyToken"], thread.source_id)`;
  the group re-run is unchanged (never sends).
- A 1:1 `message` whose `type` is not `text` gets
  `Labels.t(:text_only, locale)`: 「我目前只看得懂文字訊息，請用文字告訴我。」 /
  "I can only read text messages for now; please type it out." Thread without
  a locale gets the language picker as for text. Nothing is stored. Group non-text
  stays ignored.

## 7. Payments and attribution

- `student_summary` output adds the student's `claimed` payments: id, amount,
  method, paid_on, package.
- `Conversation` confirms with `"line:" <> source_id`.

## 8. Tests

Permanent, existing conventions:

- `enroll`: request + new student creates student with LINE id, enrolls, and
  applies the request to the Purchase; request + snapshot student links the LINE
  id; already-handled request fails and books nothing; new student whose LINE id
  got linked meanwhile fails.
- `book_makeup`: request applied with the Attendance; handled request rolls back.
- Postbacks: 幫他報名 / 幫他補課 leave the request pending, append the teacher
  message, reply through the token; non-teacher gets `:unknown_action`.
- Cards: request kinds carry the shortcut and 已處理.
- `ProcessEventWorker`: a later event for the same chat snoozes while an
  earlier one is unprocessed; a stale earlier one doesn't block; a different
  chat isn't blocked; teacher edit re-run pushes; 1:1 sticker gets the text-only
  reply.
- `Line.record_event/1` + controller: insert failure answers 500.
- `student_summary` shows claimed payment ids.

Smoke (`priv/scripts/line_smoke.exs`) steps 12–13: 幫他報名 proposes one
`enroll` with `signup_request_id` and `new_student_name`; confirming it
creates the student and applies the request.

## Out of scope (found in the review, not built here)

Student self-service in 1:1 (schedule, credits, booking); proactive pushes to
students (reminders, cancellations, request outcomes); parent booking for a
child; 1:1 blocklist and per-sender rate limits; retention of Student-chat text
and purge on unfollow; room chats; Draft expiry; web-only capabilities with no
task (edit student, refund, remove from session, reschedule, monthly close);
LLM token/cost telemetry; per-teacher DraftNotifier retry; overpayment check in
`record_payment`; LINE push retry keys; stale `line-feature-overview.html`.
