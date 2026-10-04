# LINE Teacher Assistant — Design

**Date:** 2026-10-02
**Status:** approved design; implementation planned in five slices

> **Superseded in part (2026-10-04):** reply packing (§6.2), Draft cards, lookup cards
> and `show_card` are replaced by `2026-10-04-line-chat-first-replies-design.md`.

**Builds on:** `2026-09-11-line-ai-chat-design.md` (webhook, threads, Drafts, Group chat)
**Decisions:** `docs/adr/0001-every-line-write-is-a-draft.md`,
`docs/adr/0002-line-tools-are-use-cases.md`,
`docs/adr/0003-group-chat-text-is-never-summarized.md`
**Vocabulary:** `GLOSSARY.md` — Slot, Session, Package, Enrollment, Credit, No-show,
Teacher chat, Group chat, Student chat, Draft, Confirm, Discard.

## 1. Goal

The Teacher chat can do the studio work the web UI can, driven by Claude Sonnet 5.5
(`claude-sonnet-5-5`, overridable with `ANTHROPIC_MODEL`). The model makes the
decisions (which student, which Slot or Session, which Package, what amount) and asks
when unsure; code performs every step and enforces every rule.

## 2. Rules

1. Every ledger change requested in LINE becomes a Draft; only the teacher's Confirm
   applies it (ADR 0001). The language setting is not a ledger change and applies
   immediately.
2. Confirm re-runs the change through the same domain functions the web UI calls. A
   change that no longer fits fails with a reason; nothing is written.
3. A correction replaces the earlier Draft (`replaced`), so one fact never has two live
   Drafts.
4. Tools are whole tasks, not copies of web-screen buttons (ADR 0002). The model gets a
   studio snapshot with every message instead of looking things up step by step.
5. When the model cannot decide (two students named Amy, two Tuesday Slots), it asks
   with quick-reply options instead of guessing.
6. Cards are a fixed set designed in code. The model picks a card; it never lays one
   out or writes its numbers. A Draft card shows only the Draft's stored values.
7. The Teacher chat gets every task. The Group chat gets three: record payment,
   single-class/trial booking, makeup request. Student chats get none (only
   `set_language`).

## 3. Scope

### 3.1 Tasks

| # | Task (`name`) | Kind | Domain call |
|---|---|---|---|
| 1 | `next_session` — today's or the next Session and who is coming | lookup | `Studio.next_session/0`, `Roster.list_for_session/1` |
| 2 | `month_schedule` — a month's Sessions | lookup | `Studio.sessions_in_month/1`, `Roster.count_by_session/1` |
| 3 | `session_roster` — one Session's roster | lookup | `Studio.get_session!/1`, `Roster.list_for_session/1` |
| 4 | `student_summary` — owed, purchases, payments, open Credits | lookup | `Reporting.outstanding_for_student/1`, `Sales.list_purchases_for_student/1`, `Roster.list_for_student/1`, `Roster.available_credits/2` |
| 5 | `month_money` — revenue, owed, tax threshold | lookup | `Reporting.revenue_for_month/1`, `Reporting.outstanding_by_student/0`, `Reporting.tax_threshold_status/1` |
| 6 | `open_credits` — open and expiring Credits | lookup | `Reporting.open_credits/1` |
| 7 | `cancel_session` (reason required) | change | `Scheduling.cancel_session/2` (new) |
| 8 | `set_session_style` | change | `Studio.set_style/2` |
| 9 | `add_session` — one-off Session | change | `Studio.create_session/1` |
| 10 | `add_slot` — new weekly Slot and its Sessions for a month | change | `Scheduling.add_weekly_class/2` (new) |
| 11 | `copy_month` — copy the previous month's schedule | change | `Studio.copy_month/1` |
| 12 | `enroll` — one Enrollment per Draft | change | `Enrolling.enroll_month/1` |
| 13 | `book_one_off` — 單堂 or 體驗 in one Session | change | `Enrolling.add_one_off/4` |
| 14 | `record_payment` — recorded and confirmed together | change | `Sales.record_payment/1` + `Sales.confirm_payment/2` |
| 15 | `confirm_payment` — a claimed payment entered on the web | change | `Sales.confirm_payment/2` |
| 16 | `override_price` | change | `Sales.update_purchase/2` |
| 17 | `set_no_show` — mark or undo | change | `Roster.mark_no_show/1` / `Roster.mark_expected/1` |
| 18 | `book_makeup` | change | `Roster.book_makeup/3` |
| 19 | `add_student` | change | `People.create_student/1` (+ `People.add_alias/2`) |
| 20 | `save_package` — create or edit | change | `Catalog.create_package/1` / `Catalog.update_package/2` |
| 21 | `makeup_request` — a student asked for a makeup; acknowledged only | change | none (marks applied, as today) |
| 22 | `pending_drafts` — every pending Draft as a carousel | lookup | `Assistant.list_pending_drafts/0` (new) |

"Several students" (Q15 item 12) means several Drafts, one per Enrollment, in one
carousel. A confirmed payment for an already-closed month is not a failure:
`Sales.confirm_payment/2` refreshes that month's frozen totals.

### 3.2 Control tools (not tasks the teacher asks for)

- `ask_teacher(question, options[])` — 2–13 options, each ≤ 20 characters, sent as
  quick-reply buttons that send their text back as a normal message.
- `set_language(locale)` — `zh-TW` or `en`. Teacher chat and Student chats.

### 3.3 Out of scope

Publishing and its bank/announcement settings, closing a month, login and account
screens, dev pages, model-designed cards, editing sent LINE messages (impossible),
posting in the Group chat, tools for Student chats.

## 4. Architecture

### 4.1 Modules

| Module | Responsibility |
|---|---|
| `Ganesha.Assistant.Task` | Behaviour every task and control tool implements (§4.2). |
| `Ganesha.Assistant.Tasks.*` | One module per task in §3.1 and §3.2. |
| `Ganesha.Assistant.Tasks` | Registry: which chat gets which tasks; name lookup; tool schemas. |
| `Ganesha.Assistant.Turn` | Struct the agent returns for one turn. |
| `Ganesha.Assistant.Agent` | Tool loop over tasks; persists messages; returns a `Turn`. |
| `Ganesha.Assistant.Prompts` | System prompts (moved out of `Ganesha.Assistant`). |
| `Ganesha.Assistant.Snapshot` | Studio snapshot text. |
| `Ganesha.Assistant.Memory` | Level 1 window, Level 2/3 summaries, digest writing and invalidation. |
| `Ganesha.Assistant.Digest` | Schema for `assistant_digests`. |
| `Ganesha.Assistant.DigestWorker` | Nightly Oban cron job. |
| `Ganesha.Assistant.Conversation` | Runs a 1:1 turn and a postback end to end (moved out of `ProcessEventWorker`). |
| `Ganesha.Assistant.GroupDraftNotifier` | Oban job pushing Group chat Drafts to the Teacher chat. |
| `Ganesha.Line.Cards` | The fixed card designs: Flex JSON and history lines. |
| `Ganesha.Line.Labels` | Card and button labels per locale. |
| `Ganesha.Line.Reply` | Packs a `Turn` into ≤ 5 LINE messages. |
| `Ganesha.Scheduling` | Multi-step schedule changes shared by the web UI and LINE. |

Removed: `Ganesha.Assistant.Tool` and the eight modules in
`lib/ganesha/assistant/tools/` (with their tests), `Assistant.tools/0`,
`Assistant.apply_draft/2` (replaced by `Assistant.confirm_draft/2`).

### 4.2 Contracts

```elixir
defmodule Ganesha.Assistant.Task do
  @type ctx :: %{thread: Ganesha.Assistant.Thread.t(), locale: String.t(), today: Date.t()}
  @type card :: {atom(), term()}

  @callback name() :: String.t()
  @callback kind() :: :lookup | :change | :control
  # description and input_schema only; the registry adds name and the shared fields
  @callback tool() :: %{description: String.t(), input_schema: map()}

  # :change tasks
  @callback propose(input :: map(), ctx()) ::
              {:ok, %{student_id: integer() | nil, parsed: map()}} | {:error, String.t()}
  @callback apply(parsed :: map(), confirmed_by :: String.t()) ::
              {:ok, {record_type :: String.t() | nil, record_id :: integer() | nil}}
              | {:error, term()}
  @callback describe(parsed :: map(), locale :: String.t()) :: %{
              title: String.t(),
              lines: [String.t()],
              changes: [{label :: String.t(), before :: String.t() | nil, after :: String.t()}],
              web_path: String.t() | nil
            }

  # :lookup and :control tasks
  @callback answer(input :: map(), ctx()) ::
              {:ok, %{required(:data) => String.t(), optional(:card) => card(),
                      optional(:choices) => [String.t()]}}
              | {:error, String.t()}

  @optional_callbacks propose: 2, apply: 2, describe: 2, answer: 2
end
```

- `propose/2` never writes. It resolves ids, checks the request against current data,
  and captures "before" values into `parsed` (e.g. `"before_amount"`). Its `{:error,
  text}` goes back to the model as the tool result so it can ask or correct.
- `apply/2` runs inside the transaction opened by `Assistant.confirm_draft/2` and only
  calls domain functions. It must not trust `parsed` beyond the keys its own
  `propose/2` wrote (`Map.take/2`), because `parsed` started as model output.
- `describe/2` reads only `parsed`; it never queries current data.

```elixir
Ganesha.Assistant.Tasks.for_chat(:teacher | :group | :student) :: [module()]
Ganesha.Assistant.Tasks.fetch(name :: String.t()) :: {:ok, module()} | :error
Ganesha.Assistant.Tasks.tool_schemas([module()]) :: [map()]
# adds "name"; adds optional "replaces_draft_id" (integer) to :change tasks;
# adds optional "show_card" (boolean) to :lookup tasks

defmodule Ganesha.Assistant.Turn do
  defstruct text: nil, draft_ids: [], cards: [], choices: []
end

Ganesha.Assistant.Agent.run(thread, tasks :: [module()], system :: String.t(),
                            history :: [Ganesha.Assistant.Message.t()]) ::
  {:ok, Ganesha.Assistant.Turn.t()} | {:error, term()}
```

Agent dispatch per tool call:
- `:change` → `propose/2`, then `Assistant.create_draft(thread, %{kind: name, student_id:,
  parsed:}, replaces: input["replaces_draft_id"])`; tool result
  `"draft #<id> created (<name>, pending confirmation)"`; id appended to `draft_ids`.
- `:lookup` → `answer/2`; tool result is `data`; `card` kept only when
  `input["show_card"] == true`.
- `:control` → `answer/2`; `choices` (if any) become `Turn.choices`.
- Unknown tool name → `"unknown tool: <name>"`.
- Limits: 6 rounds (`{:error, :max_iterations_exceeded}` after), `max_tokens: 4096` in
  `Provider.Anthropic`.

```elixir
Ganesha.Assistant.create_draft(thread, attrs, opts \\ []) :: {:ok, Draft.t()} | {:error, Ecto.Changeset.t()}
  # opts[:replaces] = id: in one transaction, inserts the new Draft and, if the old one
  # belongs to the same thread and is pending, sets it to "replaced" with replaced_by_id
Ganesha.Assistant.confirm_draft(draft, confirmed_by :: String.t()) ::
  {:ok, Draft.t()} | {:error, :not_pending} | {:error, {:failed, Draft.t()}}
  # claims pending → applied exactly once (existing compare-and-set), calls the task's
  # apply/2 in the same transaction; on {:error, reason} the transaction rolls back and
  # the Draft is then set to "failed" with failure_reason; an exception rolls back and
  # leaves it pending
Ganesha.Assistant.discard_draft(draft) :: {:ok, Draft.t()} | {:error, :not_pending}
Ganesha.Assistant.list_pending_drafts() :: [Draft.t()]   # oldest first, student preloaded

Ganesha.Assistant.Prompts.teacher(locale, snapshot :: String.t(), summaries :: String.t() | nil) :: String.t()
Ganesha.Assistant.Prompts.student(locale) :: String.t()
Ganesha.Assistant.Prompts.group() :: String.t()
Ganesha.Assistant.Prompts.digest(locale) :: String.t()
Ganesha.Assistant.Snapshot.build(today :: Date.t()) :: String.t()

Ganesha.Assistant.Memory.history(thread, :teacher | :student, now :: DateTime.t()) :: [Message.t()]
Ganesha.Assistant.Memory.summaries(thread, today :: Date.t()) :: String.t() | nil
Ganesha.Assistant.Memory.write_missing_digests(thread, today :: Date.t()) :: :ok
Ganesha.Assistant.Memory.invalidate_digests(thread_id, date :: Date.t()) :: :ok

Ganesha.Assistant.Conversation.handle_message(thread, reply_token, source_id) :: :ok
Ganesha.Assistant.Conversation.handle_postback(params :: map(), reply_token, source_id, teacher_id) :: :ok

Ganesha.Line.Cards.render(card, locale) :: map()          # one Flex bubble
Ganesha.Line.Cards.history_line(card, locale) :: String.t()
Ganesha.Line.Cards.draft_carousel([Draft.t()], locale) :: map()   # Flex "carousel", ≤ 12
Ganesha.Line.Labels.t(key :: atom(), locale) :: String.t()
Ganesha.Line.Reply.build(turn, drafts :: [Draft.t()], locale) :: [map()]   # ≤ 5 messages
Ganesha.Line.Reply.history_text(turn, drafts, locale) :: String.t() | nil

Ganesha.Line.ClientBehaviour  # new callbacks:
  @callback loading(chat_id :: String.t(), seconds :: pos_integer()) :: :ok | {:error, term()}
  @callback validate_reply(messages :: [map()]) :: :ok | {:error, term()}

Ganesha.Scheduling.cancel_session(session, reason :: String.t()) ::
  {:ok, %{session: Session.t(), credits: [Credit.t()]}} | {:error, Ecto.Changeset.t()}
Ganesha.Scheduling.add_weekly_class(slot_attrs :: map(), month :: Date.t()) ::
  {:ok, %{slot: Slot.t(), sessions: [Session.t()]}} | {:error, Ecto.Changeset.t()}
```

Card types (`{type, payload}`): `{:draft, Draft.t()}`, `{:session, map()}`,
`{:month, map()}`, `{:money, map()}`, `{:student, map()}`, `{:credits, map()}`. The
lookup task that returns a card builds its payload; `Cards` only renders it.

## 5. Data

### 5.1 `drafts`

- `kind`: the task `name`. Validated with `Tasks.fetch/1`, not a fixed list.
- `parsed`: unchanged name; the task's details including "before" values.
- `state`: `pending | applied | discarded | replaced | failed`; all but `pending` final.
- New columns: `failure_reason :string`, `replaced_by_id :integer` (references
  `drafts`), `notified_at :utc_datetime`.
- New index: `[:state, :thread_id]`.
- Data migration: `payment` → `record_payment`; `makeup_request` unchanged; pending
  `attendance` and `unknown` Drafts → `discarded`; `applied`/`discarded` rows of those
  kinds keep their old `kind` (history) — so `Draft.changeset/2` validates `kind` only
  on insert.

### 5.2 `assistant_digests` (new)

`thread_id` (references `assistant_threads`, delete cascade), `kind` (`daily | weekly`),
`period_start :date`, `period_end :date`, `content :text`, timestamps. Unique
`[:thread_id, :kind, :period_start]`.

### 5.3 Unchanged

`assistant_messages` (card lines are appended to the assistant's final reply text);
`assistant_threads` (`locale` already exists).

## 6. Flows

### 6.1 Teacher chat message

1. `ProcessEventWorker` routes a 1:1 text message to `Conversation.handle_message/3`
   (the first-contact language picker stays where it is).
2. `Line.Client.loading(source_id, 20)`.
3. `system = Prompts.teacher(locale, Snapshot.build(today), Memory.summaries(thread,
   today))`, `history = Memory.history(thread, :teacher, now)`.
4. `Agent.run(thread, Tasks.for_chat(:teacher), system, history)`.
5. Reload the thread (the turn may have changed `locale`), load the turn's Drafts,
   `messages = Reply.build(turn, drafts, locale)`.
6. Reply; on an expired or invalid reply token push instead (existing behaviour). If
   LINE rejects the messages with 400 other than for the token, log and push a
   text-only version (`turn.text` plus one line per Draft).
7. Append `Reply.history_text/3` to the turn's final assistant message.

Student chats: same, with `Prompts.student/1`, `Memory.history(thread, :student, now)`
(last 30 counted messages, no summaries, no snapshot), `Tasks.for_chat(:student)`.

### 6.2 Reply packing (`Reply.build/3`)

Order: text (if any) → lookup cards (one bubble each) → one Draft carousel. If that is
more than 5 messages, lookup cards beyond the limit are dropped. More than 12 Drafts:
the carousel shows the first 12 and the text gains a line naming how many more there
are and that `待確認草稿` lists them. Choices become a `quickReply` on the last
message. Every Flex message carries `altText` (≤ 400 characters).

Draft card: header = `describe/2` title; body = `lines`, then each change as
`label: before → after` (or `label: after` when `before` is nil); footer = 確認 and 捨棄
postback buttons (`action=confirm&draft_id=<id>`, `action=discard&draft_id=<id>`) and,
when `web_path` is set, a URI button to `GaneshaWeb.Endpoint.url() <> web_path`.

### 6.3 Confirm / Discard

Only `teacher_line_user_id` may confirm or discard (existing). `Conversation`
calls `Assistant.confirm_draft/2` or `discard_draft/1` and replies with one text
message:

| Outcome | zh-TW | en |
|---|---|---|
| applied | 已確認：<title> | Confirmed: <title> |
| discarded | 已捨棄：<title> | Discarded: <title> |
| failed | 無法套用：<title>（<failure_reason>） | Couldn't apply: <title> (<failure_reason>) |
| already applied / discarded / failed | 這筆草稿已經處理過了。 | This draft was already handled. |
| replaced | 這筆草稿已被取代。 | This draft was replaced. |
| unknown id | 找不到這筆草稿。 | Draft not found. |
| exception | 記錄失敗，請稍後再試。 | Something went wrong; please try again. |

The same outcome is appended to the Teacher chat as an assistant message, e.g.
`[已確認] 草稿 #41 收款 Amy NT$3,200`, so the model sees it.

### 6.4 Memory

- **Counted message:** role `user`, or role `assistant` with no tool calls.
- **Level 1:** the last 30 counted messages and every message after the oldest of them;
  if more than 30 counted messages were sent today (Asia/Taipei), all of today's, up to
  100 counted. The window always starts at a `user` message. Student chats: last 30
  counted only.
- **Level 3:** `weekly` digests (Monday–Sunday) whose `period_end` is at least 15 days
  before today and whose `period_start` is within 90 days.
- **Level 2:** `daily` digests after the newest Level 3 week (or within the last 14 days
  when there is none), up to and including the date of the oldest Level 1 message.
- `Memory.summaries/2` renders Level 3 then Level 2 with dated headings, or `nil` when
  both are empty.
- **Writing:** `DigestWorker` runs at `30 16 * * *` UTC (00:30 Asia/Taipei). For each
  Teacher chat thread, `write_missing_digests/2` writes a daily digest for every day in
  the last 90 days with counted messages and no digest, then a weekly digest for every
  complete week in range with no weekly digest, built from that week's daily digests.
  Digests use `Prompts.digest/1` with no tools. A digest keeps only what the ledger does
  not: arrangements, promises, open questions, discarded Drafts with reasons, and how
  the teacher names things.
- **Invalidation:** unsend or edit of a Teacher chat message deletes the daily digest
  for that message's date and the weekly digest containing it.
- Group chat and Student chats get no digests (ADR 0003).

### 6.5 Language

`set_language` updates `thread.locale` immediately and returns a one-line confirmation
in the new language. Prompts, card labels, button labels and the outcome texts in §6.3
follow `thread.locale`; ledger data (names, Slot labels, Package names) is shown as
stored. Supported: `zh-TW`, `en`.

### 6.6 Group chat Drafts

When a Group chat turn creates Drafts, insert `GroupDraftNotifier` with
`schedule_in: 180` and `unique: [period: 180, keys: [:group_id]]`. The job pushes every
pending Draft from Group chat threads with `notified_at` nil to the teacher as one
message (a text line plus a Draft carousel, ≤ 12; the rest go in the next job), then
sets `notified_at`. Pushes count toward the plan's monthly free messages; replies do
not. The web dashboard lists pending Drafts (`Assistant.list_pending_drafts/0`) with a
link to the student.

## 7. Error handling

- Agent or provider failure: log; reply with the localized apology; the job returns
  `:ok` (no retry, to avoid duplicate messages) — existing behaviour.
- `propose/2` errors go back to the model as tool results; nothing is written.
- `apply/2` errors mark the Draft `failed` with `failure_reason` (an atom name, or the
  changeset's errors joined as `field: message`). Exceptions roll back and leave the
  Draft `pending`.
- LINE reply failures: token problems → push (existing); other 400s → log, push text-only.
- `GroupDraftNotifier` push failure: `notified_at` stays nil; Oban retries (max 3).
- `DigestWorker`: one thread or day failing is logged and skipped; the next night fills
  the gap.

## 8. Testing

- Each task module: `propose/2` (resolves ids, rejects bad input with a message, writes
  nothing), `apply/2` (the domain change happens; a rule violation returns an error),
  `describe/2` (built only from `parsed`, before → after).
- `Assistant.confirm_draft/2`: applied once under concurrent calls, `failed` with a
  reason, `replaced` and `not_pending` outcomes.
- `Memory`: the Level 1 window rules (30 counted, starts at a user message, today's
  extension capped at 100), the Level 2/3 date selection, gap-filling, invalidation.
- `Reply.build/3`: never more than 5 messages or 12 bubbles, quick replies on the last
  message, `altText` present.
- `Cards`: structural tests in ExUnit; plus `mix line.validate_cards`, which sends one
  of every card through LINE's validate-reply endpoint with the dev channel token.
- `Conversation`: end to end with `Provider.Mock` and `Line.Client.Mock`, as
  `process_event_worker_test.exs` does today.
- `Scheduling`: the moved logic; existing `MonthLive`/`ScheduleLive` tests keep passing.
- Each slice ends with `priv/scripts/line_smoke.exs` updated and a real Sonnet 5.5 run
  on the dev channel.

## 9. Slices

1. **Foundation** — `Task` behaviour, `Tasks` registry, `Turn`, Agent rewrite, `Prompts`,
   `Snapshot`, Draft changes and migration, `confirm_draft/2` with replace and fail,
   Draft card and carousel, `Reply`, `Labels`, `Conversation` extraction, `loading/2`,
   `max_tokens` 4096, `Memory` (all three levels, digests, worker, invalidation),
   `set_language`, `ask_teacher`, and the Group chat's three tasks (`record_payment`,
   `book_one_off`, `makeup_request`). Old tools removed.
2. **Questions** — the six lookup tasks (§3.1 #1–6) and their five cards; `validate_reply/1`
   and `mix line.validate_cards`.
3. **Schedule** — `Scheduling` (with `MonthLive` and `ScheduleLive` moved onto it) and
   tasks #7–11.
4. **Students and money** — tasks #12, #15–20.
5. **Group delivery** — `GroupDraftNotifier`, dashboard pending list, `pending_drafts`.

Between slices 1 and 2 the Teacher chat has no lookup tasks; the snapshot answers
"who/when" questions until slice 2 lands.
