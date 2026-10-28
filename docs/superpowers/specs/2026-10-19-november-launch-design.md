# November launch: prod deploy and Students from group members

**Date:** 2026-10-19
**Status:** approved design, pending written-spec review
**Decisions:** `docs/adr/0004-group-members-become-students-without-confirm.md`
(amends ADR 0001)
**Follows:** `2026-10-07-line-flow-fixes-design.md`

## Goal

Run November 2026 through Ganesha in the real studio. The pasted monthly document
stays the official record for November (a shadow run); Ganesha runs alongside it.
Comparing the two every month is a separate design (Spec B, brainstormed
mid-November against real data).

This spec covers what must be true before 1 November:

1. Ganesha runs on Fly under a new studio LINE Official Account that sits in the
   real student group.
2. The Group chat knows which Student sent each message, because every group member
   is turned into a Student, or flagged to the teacher when that is unclear.

## Context

- The teacher runs the studio from her personal LINE account. The Official Account
  is new, so it is unverified: the member list endpoint
  (`GET /v2/bot/group/{groupId}/members/ids`) is unavailable. A member's LINE user
  id is known only from a webhook: a `message` they post or a `memberJoined` event.
- Data starts empty. No import, no carried-over Credits from October.
- Classes never carry over by themselves. Sessions are created only by
  `Scheduling.add_weekly_class/2` (one chosen month) or `copy_month` at the
  teacher's request; no cron job creates Sessions. This stays an invariant.
- Today the group model cannot see who is talking. `ProcessEventWorker` stores
  `sender_id` / `sender_name` on each group message, but `Agent.run/4` sends only
  the text, and `Prompts.group/0` says to propose nothing when the student is
  unclear. A payment message that doesn't name its sender never becomes a Draft.
- The default model is `claude-haiku-5-5` (commit `b722241`); `ANTHROPIC_MODEL`
  overrides it.

## Decisions

1. A group member is resolved to a Student on their first `message` or
   `memberJoined` event after the bot joins. Creating or linking that Student needs
   no Confirm (ADR 0004). Every other write stays a Draft.
2. When the match is unclear, the teacher is asked with a card; nothing is guessed.
3. Every teacher gets an immediate notice for each created, linked or unclear
   member, with an undo.
4. Each group message reaches the model with a sender tag naming the Student (or
   saying there is none). The tag is built at turn time and never stored.
5. The member state the teacher decided lives in a new `line_members` table.

## 1. Resolving members

### Entry points

`Ganesha.Assistant.ProcessEventWorker`:

- `route/1` for group `message`: after the existing group-blocked, teacher and
  sender-blocked checks, resolve the sender, then run the group turn as today.
- New `route/1` clause for group `memberJoined`: for each `joined.members[].userId`,
  apply the same skips (group blocked, teacher, sender blocked) and resolve.
  Nothing else happens on join.

The display name comes from the existing `get_group_member/2` lookup (already done
for `sender_name`; do it once per event). If the lookup fails, the name is nil and
resolution is skipped for this event; the next event tries again.

### `People.resolve_line_member(line_user_id, display_name)`

Names compare after `String.normalize(:nfkc) |> String.trim() |> String.downcase()`.
A Student matches when their `display_name` or any alias compares equal.

| # | Case | Result |
|---|---|---|
| 1 | Student already has this `line_user_id` | `{:known, student}` |
| 2 | `line_members` row, state `not_student` | `:not_student` |
| 3 | `line_members` row, state `unsure` | `:pending` (no new notice) |
| 4 | No Student matches | `{:created, student}`: `display_name` = LINE name, `line_user_id` set |
| 5 | Exactly one match, active, no `line_user_id` | `{:linked, student}`: `line_user_id` set |
| 6 | Several matches, or the one match is inactive or linked to another LINE id | `{:unsure, candidates}`: `unsure` row inserted |

Cases 4–6 run in one transaction. A unique-constraint race on `line_user_id`
(two events for one member processed concurrently) re-reads and returns case 1.
Results 4–6 enqueue a `MemberNoticeWorker` job (§2) in the same transaction.

### `line_members` table

| column | type | notes |
|---|---|---|
| `line_user_id` | string | unique |
| `display_name` | string | LINE name when the row was written |
| `state` | string | `not_student` or `unsure` |
| timestamps | | |

A row exists only while the answer is `not_student` or still open; linking or
creating a Student from an `unsure` row deletes it.

### Sender tag

In `run_group_agent/1`, user messages with a `sender_id` are sent to the model with
a prefix computed from current data:

| sender | tag |
|---|---|
| linked Student | `[student 12 小美]` |
| `not_student` | `[LINE 小美, not a student]` |
| `unsure` or not resolved | `[LINE 小美, unmatched]` |
| `sender_id` nil (older or purged rows) | none |

The stored `content` is unchanged, so the 24 h purge of `content`, `sender_id` and
`sender_name` still applies. `Prompts.group/0` gains: "Each student message starts
with a tag naming who sent it. When the message is about the sender, use the
student id in the tag. A tag without a student id means the sender is not a known
student: propose nothing for them unless the message names a student in the
snapshot."

## 2. Notices and undo

### `MemberNoticeWorker`

Oban worker, `queue: :default`, `max_attempts: 3`. Args: kind (`created`, `linked`,
`unsure`), `line_user_id`, `display_name`, student id or candidate ids. Pushes one
message to every id in `Line.teacher_ids()`, in that teacher's locale (the lookup
`DraftNotifier` uses). As in `DraftNotifier`, the job fails and retries only when no
teacher's push succeeded; it never fails the group event. Each teacher whose push
succeeded also gets 「[通知] {text}」 / "[Notice] {text}" appended to her Teacher chat as
an assistant message, so the model knows what she saw (added 2026-10-29: she tapped
不是學生 on connie's card, then typed 「她是學生」, and the model had no idea what card
she meant).

| kind | text (zh-TW) | buttons |
|---|---|---|
| created | 「新增學生 小美（LINE：小美）」 | **是學生** · 不是學生 |
| linked | 「已把 LINE 小美 連到學生 小美」 | **是學生** · 不是學生 · 連錯了 |
| unsure | 「LINE 小美 是哪位學生？」 | up to 3 candidates · 新學生 · 不是學生 |

English text follows the existing `Labels` pattern. With more than 3 candidates the
unsure card adds 「還有 N 位同名，請到網頁處理」 / "N more with this name; fix it on
the web". Cards are fixed layouts in `Ganesha.Line.Cards`; text goes through
`Ganesha.Line.Labels`.

Every group member is expected to be a Student, so 是學生 (primary) leads; the undo
buttons are secondary. A card's lone 不是學生 button read as "OK" and was tapped by
mistake (2026-10-28).

### Postbacks

Handled in `Conversation.handle_postback/3`, teacher only (non-teachers get
`:unknown_action` as today). Data carries `action`, `uid` (LINE user id) and,
where needed, `sid` (Student id) and `name`. Every tap first re-checks the current
state; a member no longer in the state the button expects gets the existing
"already handled" reply and nothing changes.

| action | expects | effect |
|---|---|---|
| `member_ok` | Student `sid` linked to `uid` | nothing; replies 「好，{name} 是學生。」 |
| `member_not_student` (from created) | Student `sid` linked to `uid` | insert `not_student` row; delete the Student if they have no purchases, attendances, payments or credits, else clear `line_user_id` and keep them |
| `member_not_student` (from linked) | Student `sid` linked to `uid` | insert `not_student` row; clear `line_user_id` |
| `member_not_student` (from unsure) | `unsure` row | row state → `not_student` |
| `member_wrong_link` | Student `sid` linked to `uid` | clear `line_user_id`; insert `unsure` row; enqueue an unsure notice with fresh candidates |
| `member_pick` | `unsure` row; `sid` active and unlinked | link `sid`; delete row |
| `member_new` | `unsure` row | create Student (`name`, `uid`); delete row |

The postback data says which notice it came from (`from=created|linked|unsure`),
which decides between deleting and unlinking. Two teachers tapping different
answers: the first tap wins; the second gets "already handled".

Every answer that changed or confirmed something is appended to the tapping
teacher's chat as 「[通知回覆] {reply}」 / "[Notice answer] {reply}"; an "already
handled" reply leaves no line.

### What the model is told

The Teacher prompt (rule 15) says everyone in the studio group is a Student, that the
system adds them as they post or join, and that LINE gives no full member list, so the
bot only knows members who posted or joined since it arrived. `listening` shows each
sender's Student (`student 12 Connie`, `not a student`, `waiting for the teacher to
pick the student`, `no student yet`, or `teacher`) and is the lookup for "who is in
the group". A confirmed Draft's history line names the record it made
(「[已確認] 草稿 #1 新增學生 connie → student 2」), so the model doesn't take its own new
Student for a duplicate.

### Push quota

Draft pushes and these notices count against the Official Account's monthly push
quota. Starting empty, the first week sends one notice per active member per
teacher. The launch checklist checks the plan; no batching is built.

## 3. Launch checklist

Ordered; feature code is deployed before the bot joins the group.

| # | Step | Who |
|---|---|---|
| 1 | New Anthropic API key into `.env.dev` and Fly secret `ANTHROPIC_API_KEY`; unset any `ANTHROPIC_MODEL` secret | Mickey |
| 2 | Create the studio Official Account with Messaging API; copy channel secret and long-lived access token; disable auto-reply and greeting; allow joining groups; check the plan's push quota | Mickey |
| 3 | `flyctl auth login`; then list current secrets and inspect the prod volume | Mickey, then agent |
| 4 | Fly secrets `LINE_CHANNEL_SECRET`, `LINE_CHANNEL_ACCESS_TOKEN`, `TEACHER_LINE_USER_ID` | agent, with Mickey's values |
| 5 | Tigris bucket (`fly storage create`) and `LITESTREAM_ENDPOINT`, `LITESTREAM_BUCKET`, `LITESTREAM_ACCESS_KEY_ID`, `LITESTREAM_SECRET_ACCESS_KEY` secrets | agent |
| 6 | If the volume holds September test data, wipe it after Mickey's explicit yes; `fly deploy` `main` with this spec built (`bin/server` migrates on boot) | agent, Mickey approves wipe |
| 7 | Seed the web login (`seeds.exs` with `TEACHER_EMAIL` / `TEACHER_PASSWORD`); `/health` answers; web UI loads on her phone | agent, then teacher |
| 8 | Webhook URL `https://ganesha.fly.dev/line/webhook`, "Use webhook" on, Verify | Mickey |
| 9 | Teacher messages the bot 1:1 and gets a Teacher chat reply | teacher |
| 10 | Add the bot to the student group; the first member post sends a notice | Mickey |
| 11 | Before 1 Nov: teacher creates November Slots and Packages in the Teacher chat | teacher |
| 12 | Optional: tell students a bot reads the group | Mickey |

## 4. Tests

Permanent, existing conventions:

- `People.resolve_line_member/2`: every row of the §1 table; normalization (case,
  full-width, alias match); inactive single match is unsure; nil name is skipped by
  the caller.
- `ProcessEventWorker`: a group message from an unknown member creates the Student
  before the turn and the turn's wire messages carry `[student N name]`;
  `memberJoined` resolves each joined member; teacher and blocked senders are not
  resolved; a member with an `unsure` row enqueues no second notice.
- Postbacks: each action's effect; a stale tap gets "already handled"; a
  non-teacher tap is refused; `member_not_student` from created deletes a Student
  with no records and only unlinks one with records.
- `MemberNoticeWorker`: pushes to every teacher in her locale; the job fails when
  every push failed and succeeds when at least one went out.

After deploy: checklist steps 9 and 10 on the real account.

`GLOSSARY.md` gains **Group member**: a LINE user seen in the Group chat, resolved
to a Student, marked not a student, or waiting for the teacher.

## Out of scope

- Monthly comparison of Ganesha with the pasted document (Spec B).
- Listing every group member up front (needs a verified or premium account).
- Batching notices into a daily summary.
- Carried-over Credits from before Ganesha.
- Resolving members of Student chats (they link through sign-up requests as today).
