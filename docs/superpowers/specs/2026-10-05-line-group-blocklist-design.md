# LINE assistant: group blocklist, never-reply guards, dev retention

Extends `2026-10-02-line-teacher-assistant-design.md` (Group chat, Drafts,
`GroupDraftNotifier`) and amends §7 of `2026-09-11-line-ai-chat-design.md`
for dev only. Everything else in those specs stands.

## Problem

The bot is about to join the teacher's real student group. It already listens
to every group it is invited into, proposes Drafts from student messages, and
pushes them to every teacher to confirm. Three things are missing:

1. No way to stop it listening to a group, or to one person, short of removing
   the bot.
2. "Never posts in the group" rests only on the group path not calling LINE.
   One wrong call elsewhere, or LINE's own auto-response, would break it.
3. During development, group text is purged after 24h, so there is no local
   record to debug or replay against.

## Decisions

1. **Blocklist covers groups and senders.** A blocked sender is ignored in
   every group, keyed by LINE `userId`.
2. **Managed from the Teacher chat**, as Drafts the teacher confirms (ADR 0001).
   No env var, no web page.
3. **The teacher names senders by LINE display name**, resolved to an exact
   `userId` through a lookup before the Draft is proposed.
4. **One table, `blocked_accounts`.** Unblocking deletes the row.
5. **Two code guards keep the bot out of group chats**, plus one manual LINE
   setting.
6. **Raw text is kept in dev, purged at 24h in prod and test.**
7. **Group delivery is unchanged:** any group the bot joins is listened to unless
   blocked, and every configured teacher gets the Draft push.

## 1. Data

### `blocked_accounts`

Schema `Ganesha.Line.BlockedAccount`, managed by the `Ganesha.Line` context.

| column | type | note |
|---|---|---|
| `kind` | string, required | `"group"` or `"sender"` |
| `line_id` | string, required | groupId (`C…`) or userId (`U…`) |
| `label` | string, required | group name or LINE display name, captured when the block is proposed |
| `inserted_at` | utc_datetime | |

The confirmed Draft already points at its row through `applied_record_type`
and `applied_record_id`, so the table has no back-reference to `drafts`.
(`apply/2` never receives the Draft, so a `draft_id` column could not be filled.)

Unique index on `(kind, line_id)`. No `updated_at`: rows are inserted and
deleted, never edited.

`Ganesha.Line` adds:

- `blocked?(kind, line_id) :: boolean()`
- `list_blocked_accounts() :: [BlockedAccount.t()]`, newest first
- `block_account(attrs) :: {:ok, BlockedAccount.t()} | {:error, :already_blocked | Ecto.Changeset.t()}`
- `unblock_account(kind, line_id) :: :ok | {:error, :not_blocked}`

### Sender on group messages

`assistant_messages` gains `sender_id` (string, nullable) and `sender_name`
(string, nullable). Only group-thread `user` messages set them. `sender_name`
comes from `Line.Client.get_group_member/2`. If that call fails, the name is
stored as `nil` and the message is still processed.

`Assistant.append_message/5` accepts `sender_id:` and `sender_name:` options
alongside `line_message_id:`.

## 2. Routing

`ProcessEventWorker.route/1` for a group `message` event, in this order:

1. Group in `blocked_accounts` → `:ok`.
2. Sender is a teacher → `:ok` (unchanged).
3. Sender in `blocked_accounts` → `:ok`.
4. Otherwise: `get_group_member` → append the message with sender → run the
   group agent → `maybe_schedule_group_notifier` (unchanged).

Checks 1 and 3 run before anything is appended. Blocked text never enters the
group thread or reaches the model, and costs no `get_group_member` call.

`messageEdited` on a group thread whose group is blocked updates the stored
text but does not re-run the agent. An edit from a blocked sender is handled
the same way: their earlier messages were stored before the block, so the
stored text is updated but the agent is not re-run.

The webhook still persists every event to `line_events`, blocked or not. Its
budget (verify → persist → 200) does not change.

## 3. Teacher chat tasks

All three go in `Tasks.for_chat(:teacher)` only. None is added to the
Group chat task list.

### `listening` (`:lookup`)

Answers "which groups are you in, who has been posting, who is blocked". The
`data` text contains:

- **Groups:** every `assistant_threads` row with `source_type == "group"`,
  each with its name from `Line.Client.get_group_summary/1` (falls back to the
  group id when the call fails) and whether it is blocked.
- **Recent senders:** per group, distinct `(sender_id, sender_name)` from
  messages whose `sender_id` is still set, newest first, at most 30 per group,
  each with its last-seen time (Taipei). In prod that window is 24h because of
  the purge; in dev it is everything.
- **Blocked:** every `blocked_accounts` row: kind, label, `line_id`, date.

### `block_account` (`:change`)

Input: `kind` (`"group"` | `"sender"`), `line_id`.

`propose/2`:

- `kind == "group"`: `line_id` must be a group thread's `source_id`; `label`
  is the group summary name, or the id if that call fails.
- `kind == "sender"`: `line_id` must appear as a `sender_id` on a stored group
  message; `label` is a stored non-nil `sender_name` for it (SQL `max`, so a
  renamed sender may show either name), or the id. In prod the
  purge limits this to senders seen in the last 24h, which is accepted: the
  teacher blocks someone right after seeing their messages.
- Rejects a teacher's userId, an already-blocked account, and an unknown id,
  each with an error text for the model.
- `parsed`: `kind`, `line_id`, `label`.

`apply/2` calls `Line.block_account/1` and returns
`{:ok, {"Ganesha.Line.BlockedAccount", id}}`. A concurrent block returns
`{:error, :already_blocked}`.

`summary/2` examples:

- sender, zh-TW: `封鎖 小美：之後所有群組中這個人的訊息都不再讀取`
- group, zh-TW: `封鎖群組「瑜伽週三班」：之後不再讀取這個群組`
- en: `Block 小美: their messages in every group will be ignored`,
  `Block group "瑜伽週三班": stop reading this group`

### `unblock_account` (`:change`)

Input: `kind`, `line_id`. `propose/2` requires an existing row and copies its
`label` into `parsed`. `apply/2` calls `Line.unblock_account/2` and returns
`{:ok, {nil, nil}}`, or `{:error, :not_blocked}` if the row is gone.
`summary/2`: `解除封鎖 小美：之後會再讀取這個人在群組中的訊息` /
`Unblock 小美: their group messages will be read again`. For a group:
`解除封鎖群組「瑜伽週三班」：之後會再讀取這個群組` /
`Unblock group "瑜伽週三班": read this group again`.

### Supporting changes

- `Draft` accepts kinds `block_account` and `unblock_account` (registering the
  tasks is enough: `Draft.validate_kind/1` looks them up in `Tasks`).
- Summary sentences are written inline in each task's `summary/2` in zh-TW and
  en, as the existing tasks do.
- Teacher prompt: one line saying that when a name matches more than one
  account in `listening`, use `ask_teacher` rather than picking one.
- `Line.ClientBehaviour` and `Line.Client.Mock` gain `get_group_summary/1`.
  Mock returns `%{"groupName" => "測試群組"}`.

## 4. Never posting in a group

1. **No reply token is stored.** `Line.record_event/1` removes `"replyToken"`
   from the payload of events whose `source.type` is `"group"` or `"room"`
   before inserting. No later code can reply into a group.
2. **Client refuses group targets.** `Line.Client.push/2` and `loading/2`
   return `{:error, :group_target_forbidden}` without an HTTP call when the
   target starts with `"C"` or `"R"`, and log an error. This holds for every
   caller, present and future.
3. **LINE's own auto-response** is sent by LINE, not this code. The setup
   guide adds a step: OA Manager → Settings → Response settings → Chat off,
   Auto-response off, Webhook on. The same step turns on Account settings →
   "Allow account to join groups and multi-person chats".

The existing group-path test (`Client.Mock.calls/0` stays empty) remains.

## 5. Retention

- New config `:ganesha, :line, purge_raw_text` (default `true`).
  `config/runtime.exs` sets it to `false` in the dev block. Prod and test keep
  `true`.
- `PurgeGroupRawTextWorker.perform/1` returns `:ok` without touching anything
  when the flag is `false`. The cron entry stays.
- When the flag is `true`, the purge also nils `sender_id` and `sender_name`
  on group messages older than 24h.
- With the flag off, dev keeps every raw payload, including unrecognised 1:1
  senders'. One flag is simpler than splitting the policy, and dev is the
  developer's own data.
- `2026-09-11-line-ai-chat-design.md` §7 and ADR 0003 each get a note: the 24h
  rule applies in prod; dev keeps raw text; revisit before the prod cutover.
- `blocked_accounts` rows hold only the blocked account's id and name, and only
  while blocked. That is not a member roster, so §7's "no roster" rule holds.

## 6. Testing

- **Routing:** a blocked group stores no thread message, makes no agent call,
  and makes no `get_group_member` call. The same holds for a blocked sender.
  An unblocked sender is stored with `sender_id` and `sender_name`. A
  `get_group_member` failure still runs the agent. `messageEdited` in a blocked
  group does not re-run the agent.
- **Tasks:** `block_account` propose rejects a teacher, an unknown group, an
  unknown sender, and an already-blocked account. Apply inserts the row, and a
  second apply returns `:already_blocked`. Unblock round-trips. `listening`
  shows group names, recent senders, and the blocked list.
- **Guards:** `record_event` drops `replyToken` for group and room events and
  keeps it for 1:1. `Client.push/2` to a `C…` or `R…` id returns the error and
  makes no `Req.Test` request.
- **Purge:** with the flag off, nothing changes. With it on, `sender_*` is
  cleared with `content`.
- **Smoke:** a new step in `priv/scripts/line_smoke.exs`. A Teacher-chat Draft
  blocks a sender and is confirmed. A group message from that sender then
  produces no Draft and no notifier job.

## Out of scope

- An allowlist, or restricting the bot to one group.
- Sending group Drafts to only one teacher.
- A web UI for the blocklist.
- Prod cutover and its retention review.
