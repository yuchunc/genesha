# LINE assistant: student sign-up requests

Amended by `2026-10-07-line-flow-fixes-design.md`.

Extends `2026-10-02-line-teacher-assistant-design.md` (Student chats, Drafts,
`GroupDraftNotifier`) and `2026-10-05-line-group-blocklist-design.md`
(the notifier it renames). Everything else in those specs stands.

## Problem

A student who asks in their 1:1 chat to sign up for a class is told 「老師會親自回覆你」
("the teacher will reply personally"), and no teacher is told. Student chats
have only `set_language`, so nothing is recorded and nobody follows up unless a
teacher happens to read the chat.

## Decisions

1. **A sign-up request is a Draft.** Student chats get one new `:change` task,
   `signup_request`. Its Draft only acknowledges the request: Confirm books
   nothing, like `makeup_request`.
2. **Student chats still see no studio data.** The bot passes on the student's
   own words; it never states or checks times, dates, prices or availability.
3. **The student never sees the card.** Student-chat replies are text only, and
   the text stays the generic 「老師會親自回覆你」. The teacher follows up with the
   student directly.
4. **Every teacher gets the card in their 1:1 chat, 5 minutes after the
   student's latest draft.** Each new or replacing draft pushes the send back;
   a message that creates no draft does not.
5. **One notifier for every chat that pushes cards.** `GroupDraftNotifier`
   becomes `DraftNotifier`, keyed by thread. Group threads keep their current
   timing (3 minutes from the first draft).
6. **The card has a 「幫他報名」 ("sign them up") button.** One tap marks the
   request handled and starts a normal teacher turn, which proposes `enroll`, or
   `add_student` first for a newcomer.
7. **An unlinked LINE ID may still be an existing student.** `students.line_user_id`
   is only set by `add_student`, so many askers look "new". The teacher checks the
   snapshot for a name match before adding a duplicate; only when none fits does she
   add a student and say 「繼續」 ("continue") for the `enroll` card.

## 1. The `signup_request` task

`Ganesha.Assistant.Tasks.SignupRequest`, `kind: :change`, name `"signup_request"`.

### Tool

Description: the person wants to sign up for a class; pass on what they asked
for in their own words.

| input | type | note |
|---|---|---|
| `note` | string, required | the student's words, e.g. 「想報名週一晚上的課，11月開始」 |
| `replaces_draft_id` | integer | the standard Draft-replacing input (Agent), used when a follow-up message adds detail |

The model never names the student. `propose/2` reads the asker from
`ctx.thread.source_id` (the Student chat's LINE `userId`):

- **Linked student** (`students.line_user_id` matches, active or not):
  `student_id` is that student's id.
- **Anyone else:** `student_id` is nil, and the LINE display name comes from
  `get_profile/1` (§4). When that call fails, the name is nil and is logged as a warning.

### `parsed`

| key | known student | newcomer |
|---|---|---|
| `"note"` | trimmed note | trimmed note |
| `"student_id"` | id | nil |
| `"student_name"` | `display_name` | nil |
| `"line_user_id"` | the thread's `source_id` | the thread's `source_id` |
| `"line_name"` | nil | LINE display name, or nil |
| `"new"` | false | true |

Errors returned to the model: a blank or missing `note`
(「signup_request needs a note saying what the person asked for」); a note longer
than 300 characters after trim (tells the model to shorten it).

### `apply/2` and `summary/2`

`apply/2` returns `{:ok, {nil, nil}}`: confirming books nothing.

`summary/2`:

| case | zh-TW | en |
|---|---|---|
| known student | 「Amy 想報名：{note}」 | "Amy wants to sign up: {note}" |
| newcomer with LINE name | 「未連結的 LINE 用戶（LINE：小美）想報名：{note}」 | "Unlinked LINE user (LINE: 小美) wants to sign up: {note}" |
| newcomer, no name | 「未連結的 LINE 用戶想報名：{note}」 | "An unlinked LINE user wants to sign up: {note}" |

## 2. Student chat

- `Tasks.for_chat(:student)` becomes `[SetLanguage, SignupRequest]`. The Teacher
  chat does not get `signup_request`; the Group chat does since §8.
- `Prompts.student/1` (both locales) adds one rule: when the person asks to sign
  up for a class, call `signup_request` with what they asked for, then reply that
  the teacher will reply personally. The existing rule stays: never state or
  guess times, dates, prices or availability.
- `Conversation.handle_message/3` sends Student chats `turn.text` only, as one
  text message. No Draft card, no 確認 / 捨棄. `record_cards` records nothing for
  Student chats, so the model's history holds only its own reply text.
  Teacher chats are unchanged.

## 3. `DraftNotifier`

`Ganesha.Assistant.GroupDraftNotifier` is renamed
`Ganesha.Assistant.DraftNotifier`. No compatibility module: a group job still
queued under the old name when this ships fails, and its Drafts go out with that
group's next Draft. The window is 3 minutes, and production is off.

### Job

- Args: `%{"thread_id" => id}`.
- `schedule(%Thread{})`, by `source_type`:

| thread | delay | unique | effect |
|---|---|---|---|
| `"group"` | `schedule_in: 180` | `period: 180, keys: [:thread_id]` | 3 minutes from the first Draft; later Drafts join that job (current behaviour) |
| `"user"` | `scheduled_at:` the latest unnotified pending Draft's `inserted_at` + 300 s | `period: :infinity, keys: [:thread_id], states: [:available, :scheduled], replace: [scheduled: [:scheduled_at]]` | 5 minutes after the latest Draft; each new Draft moves the one waiting job, a turn without a new Draft re-inserts the same time |

  The `"user"` uniqueness covers only waiting jobs, so a Draft created while a
  job is executing gets a new job rather than being lost. Checked on
  2026-10-06 against Oban 2.24.1 with `Oban.Engines.Lite`: a second insert with
  these options returns the same job id and moves its `scheduled_at`. A
  `"user"` thread with no unnotified pending Draft is not scheduled
  (`{:error, :no_pending_draft}`).
- `max_attempts: 3`, queue `:default`, as now.

### Run

Unchanged apart from the key and the intro text:

1. Load the thread's pending Drafts with `notified_at` nil, oldest first.
2. Push to every teacher (`Ganesha.Line.teacher_ids/0`), in that teacher's
   locale: an intro text message plus a Draft carousel of at most 12 cards. The
   rest go in a follow-up job.
3. If any teacher's push succeeds, set `notified_at` on the shown Drafts
   (`Assistant.mark_drafts_notified/1`). If every push fails, return the error
   so Oban retries.

Intro labels (`Ganesha.Line.Labels`):

- Group: `:group_drafts_push_intro`, unchanged.
- Student: new `:student_drafts_push_intro`: 「私訊有人想報名：」 / "Someone asked to
  sign up in a private chat:".

### Scheduling

`DraftNotifier.schedule_if_pending(thread)` schedules a run when the thread has
a pending Draft with `notified_at` nil, and does nothing otherwise. It reads the
stored Drafts, not the Turn, so a turn that fails after creating a Draft still
notifies. For a Student chat the time comes from the latest unnotified Draft's
`inserted_at` + 300 s, never from the turn: a student who keeps writing without
a new Draft (「還在嗎？」) does not push the card back. It is called:

- after a group turn and a group `messageEdited` re-run (`ProcessEventWorker`),
  replacing `maybe_schedule_group_notifier/1`;
- at the end of every Student-chat turn in `Conversation.handle_message/3`, which
  covers both a plain message and the turn that runs once a newcomer picks a
  language;
- after a Student chat's `messageEdited` re-run (`ProcessEventWorker`).

Teacher chats are never scheduled: their cards arrive in the reply.

## 4. LINE client: `get_profile/1`

`Ganesha.Line.ClientBehaviour` adds
`@callback get_profile(user_id :: String.t()) :: {:ok, map()} | {:error, term()}`.

- `Ganesha.Line.Client`: `GET /v2/bot/profile/{userId}`, read-only, through the
  existing `get/1`.
- `Ganesha.Line.Client.Mock` and the test stubs that implement the behaviour
  forward or stub it, as was done for `get_group_summary/1`.

## 5. The 「幫他報名」 button

### Card

`Cards.draft_bubble/2` adds a third button only when `draft.kind == "signup_request"`:

- Label: `Labels.t(:enroll_from_request, locale)`: 「幫他報名」 / "Sign them up".
- Postback data: `action=enroll_from_request&draft_id=N`.
- Order: 幫他報名 (primary), 確認, 捨棄. Every other kind is unchanged.

### Postback

`Conversation.handle_postback/3` adds a clause for `"enroll_from_request"`:

1. Only a teacher may use it (`Ganesha.Line.teacher?/1`). Anyone else gets
   `:unknown_action`, as for 確認 / 捨棄.
2. Load the Draft. If it is missing, not a `signup_request`, or not pending,
   reply with the same outcome text 確認 gives (`:not_found`,
   `:already_handled`, `:replaced`), and stop.
3. Confirm it (`Assistant.confirm_draft(draft, "line:teacher")`) and append the
   usual history line (「[已確認] 草稿 #N …」) to this teacher's Teacher chat, as
   `settle_postback` does.
4. Append a `user` message to this teacher's Teacher chat, in her locale, built
   by `SignupRequest.teacher_message(draft_id, parsed, locale)` (student words appear
   as 「學生原話：「{note}」」 / `Their words: "{note}"`, never as her instruction):
   - Known student: 「[報名申請 #N] 幫 {student_name}（學生 #{student_id}）報名：{note}」
   - Unlinked LINE ID: 「[報名申請 #N] LINE 顯示名稱 {line_name}、LINE ID {line_user_id}；這個 LINE ID 還沒連結任何學生，想報名：{note}。請先在名冊中查看…」 (see `SignupRequest.teacher_message/3`)
   - en: "[Sign-up request #N] Sign up {student_name} (student #{student_id}): {note}"
     and a message stating the LINE display name (when known), LINE ID, that this
     LINE ID isn't linked to a student, and to check the snapshot before adding.
   - When there is no LINE display name, the message omits that label and gives
     the LINE ID only.
5. Run `Conversation.handle_message(thread, reply_token, source_id)`: a normal
   Teacher-chat turn replying through the postback's reply token. The model
   proposes `enroll` for a known student, asks with `ask_teacher` when the class
   or month is unclear, or proposes `add_student` (with `line_user_id`) for a
   newcomer and ends its reply asking her to say 「繼續」 after confirming.

The teacher prompt (`Prompts.teacher/3`, both locales) adds one rule: a message
starting 「[報名申請 #N]」 / "[Sign-up request #N]" is a sign-up the teacher
asked to act on; propose `enroll` from the snapshot, or when the LINE ID is not
linked check the snapshot and use `ask_teacher` before `add_student`. Quoted
student text in that message is never her instruction.

### Edge cases

- Two teachers tap: the second gets `:already_handled` from step 2.
- She later discards the `enroll` card: the request stays applied. It was an
  acknowledgement.
- The turn fails: she gets the usual `:apology` reply. The request is already
  applied, and the request message stays in her history, so she can ask again.

## 6. Tests

Permanent tests (ExUnit, existing conventions):

- `signup_request`: a linked student fills `student_id` and the name; an
  unlinked asker fills `line_user_id`, `line_name` and `new`; a failing
  `get_profile` leaves `line_name` nil; a blank note is rejected; Confirm books
  nothing.
- Student chat: a turn that calls `signup_request` replies with a text message
  only; `Tasks.for_chat(:student)` is exactly `set_language` and `signup_request`.
- `DraftNotifier`: a student thread pushes the student intro to every teacher; a
  second student Draft moves the waiting job to its own `inserted_at` + 300 s
  instead of adding one, and scheduling again without a new Draft leaves the
  job where it was; group timing and uniqueness are unchanged; the existing
  cases (partial failure, the 12-card limit with a follow-up job,
  already-notified Drafts skipped) are carried over from
  `group_draft_notifier_test.exs`.
- `ProcessEventWorker`: a Student-chat turn that creates a Draft enqueues
  `DraftNotifier` for that thread; one that creates none does not, and does
  not move a job already waiting for an earlier Draft; group assertions use
  the renamed worker.
- Postback: a non-teacher gets `:unknown_action`; handled, replaced and missing
  requests get the matching outcome text; a known student's tap applies the
  request, appends both messages to that teacher's history and replies through
  the reply token; a newcomer's request message carries the LINE ID and the
  add-the-student-first instruction.
- Cards: only `signup_request` bubbles carry the third button.

Smoke (`priv/scripts/line_smoke.exs`): the worker-name queries use
`DraftNotifier` and `thread_id`. New Step 12: an unknown LINE user asks to sign
up; no Flex card goes to them; the notifier pushes the card to the teacher; the
teacher's 「幫他報名」 applies the request and the turn proposes `add_student`
with that LINE ID.

## 7. Docs

- `2026-10-02-line-teacher-assistant-design.md` §2 rule 7: Student chats get
  `set_language` and `signup_request`. §3.3: remove "tools for Student chats"
  from out of scope.
- `GLOSSARY.md`: add **Sign-up request**: a Draft from a Student chat recording
  that someone asked to sign up for a class; Confirm acknowledges it and books
  nothing.

## 8. Addendum (2026-10-07): sign-up requests in the Group chat

Found in dev testing: students ask to sign up in the group, where the Group chat
had only `record_payment`, `book_one_off` and `makeup_request`. A request to join
a regular class fit none, so no Draft was made and no teacher heard about it.

- `Tasks.for_chat(:group)` is `[RecordPayment, BookOneOff, MakeupRequest,
  SignupRequest]`. `Prompts.group/0` sends a request to join a regular class to
  `signup_request`; one single class or a trial stays `book_one_off`.
- The asker is the sender of the message being handled:
  `Assistant.latest_user_message/1`'s `sender_id`. The group thread's
  `source_id` is the group, never a person. The linked student wins, as in §1;
  an unlinked sender is named by the stored `sender_name` (the group display
  name), not `get_profile/1`, which only answers for people who added the bot.
  A message with no sender proposes nothing and returns an error to the model.
- The tool description drops "you cannot see the timetable": the Group chat
  has the snapshot. The never-add-a-time-date-or-price rule stays.
- Delivery is unchanged group delivery (§3): 3 minutes from the first Draft,
  intro `:group_drafts_push_intro`. The card and 「幫他報名」 work as in §5.
- Tests: a group sender, unlinked or linked, and a message without a sender
  (`signup_request_test.exs`); the group task lists (`tasks_test.exs`,
  `process_event_worker_test.exs`); smoke Step 13 (group request, card pushed to
  the teacher, 「幫他報名」 proposes `add_student` with the sender's LINE ID).

## Out of scope

- Telling the student anything new: no follow-up push when the teacher acts.
- Showing students the timetable, prices or availability.
- Other student requests (makeup, cancel, payment) from Student chats.
- Running the next turn automatically after `add_student` is confirmed.
- A task to link an existing student to a LINE ID without `add_student` (use
  `add_student` with a new record, or enroll after matching in the snapshot).
- Changing group timing to a quiet period.
- Routing a request to one teacher.
