# November Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Group chat member becomes a linked Student (or is flagged to the teacher), the group model sees who sent each message, and Ganesha goes live on Fly for November.

**Architecture:** `Ganesha.People` owns the matching rules and a new `line_members` table. `Ganesha.Assistant.GroupMembers` runs a resolution and enqueues `MemberNoticeWorker` in one transaction, and tags group history with the sender before each group turn. `ProcessEventWorker` resolves on group `message` and `memberJoined`. The teacher's taps on notices arrive as postbacks in `Conversation.handle_postback/3`.

**Tech Stack:** Elixir, Phoenix 1.8, Ecto + `ecto_sqlite3`, Oban (Lite), `Req` + `Req.Test`, LINE Messaging API.

**Spec:** `docs/superpowers/specs/2026-10-19-november-launch-design.md` (ADR `docs/adr/0004-group-members-become-students-without-confirm.md`)

## Global Constraints

- The group path never sends into a group. Notices go only to ids in `Line.teacher_ids()`, from `MemberNoticeWorker`, never inline in `ProcessEventWorker`.
- Creating or linking a Student from a group member is the only LINE write without a Confirm (ADR 0004). Every other write stays a Draft.
- Teachers' own LINE ids are never resolved, even with `:dev_teacher_posts_in_groups` on. Blocked groups and blocked senders are never resolved.
- Sender tags are built at turn time and never stored. `messages.content` is unchanged, so the 24 h purge still applies.
- Name comparison: `String.normalize(:nfkc) |> String.trim() |> String.downcase()`, against `display_name` and every alias.
- User-facing text is exactly the Labels copy in Task 2, in zh-TW and en.
- No new dependencies. Generate migrations with `mix ecto.gen.migration <name>`.
- Run `mix precommit` once all code tasks are done and fix everything it reports.

## Review Focus

1. A LINE name that differs from an existing Student only by case, spacing or full-width characters links instead of creating a duplicate. (Task 1 test `normalizes before matching`.)
2. A member who joins and then posts, or posts twice in a row, ends up as one Student with one notice. (Task 3 test `memberJoined then a message creates one student and one notice`.)
3. A member she marked 不是學生 keeps posting: they are never created again, and their messages reach the model tagged `[LINE name, not a student]`. (Task 3 test.)
4. The second teacher taps a notice the first already handled: nothing changes and she gets `member_already_handled`. (Task 4 test.)
5. A 20-character CJK display name still fits LINE's 300-character postback `data` limit. (Task 2 test.)

---

### Task 1: `line_members` and member resolution rules

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_line_members.exs` (via `mix ecto.gen.migration create_line_members`)
- Create: `lib/ganesha/people/line_member.ex`
- Modify: `lib/ganesha/people.ex`
- Test: `test/ganesha/people_test.exs`

**Interfaces:**
- Produces:
  - `Ganesha.People.LineMember` schema `"line_members"`: `line_user_id :string`, `display_name :string`, `state :string` (`"not_student" | "unsure"`), `timestamps(type: :utc_datetime)`. `changeset/2` requires all three, validates state inclusion, `unique_constraint(:line_user_id)`.
  - `@type People.resolution :: {:known, Student.t()} | :not_student | :pending | {:created, Student.t()} | {:linked, Student.t()} | {:unsure, [Student.t()]}`
  - `People.resolve_line_member(line_user_id :: String.t(), display_name :: String.t()) :: resolution()`
  - `People.matching_students(display_name :: String.t()) :: [Student.t()]`: every Student (active or not) whose normalized `display_name` or alias equals the normalized name, ordered by id.
  - `People.get_line_member(line_user_id) :: LineMember.t() | nil`

- [ ] **Step 1: Write the migration.** Table `line_members` with columns as above, all `null: false`, and `create unique_index(:line_members, [:line_user_id])`. Follow `20261005151129_create_blocked_accounts.exs`. Run `mix ecto.migrate` (dev) to check it applies.

- [ ] **Step 2: Write the failing tests** in `test/ganesha/people_test.exs`, in a `describe "resolve_line_member/2"`:

```elixir
test "an already linked student is known" do
  s = student!(%{display_name: "小美", line_user_id: "U1"})
  assert {:known, %{id: id}} = People.resolve_line_member("U1", "別的名字")
  assert id == s.id
end

test "a not_student member stays not a student" do
  Repo.insert!(%LineMember{line_user_id: "U1", display_name: "老公", state: "not_student"})
  assert :not_student = People.resolve_line_member("U1", "老公")
  assert Repo.aggregate(Student, :count) == 0
end

test "an unsure member is pending" do
  Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})
  assert :pending = People.resolve_line_member("U1", "Amy")
end

test "no name match creates a linked student named after LINE" do
  assert {:created, %Student{display_name: "小美", line_user_id: "U1"}} =
           People.resolve_line_member("U1", " 小美 ")
end

test "one active unlinked match is linked" do
  s = student!(%{display_name: "Amy"})
  assert {:linked, %{id: id, line_user_id: "U1"}} = People.resolve_line_member("U1", "Amy")
  assert id == s.id
end

test "normalizes before matching" do
  s = student!(%{display_name: "ａｍｙ Chen"})
  assert {:linked, %{id: id}} = People.resolve_line_member("U1", "AMY CHEN ")
  assert id == s.id
end

test "an alias alone matches" do
  t = student!(%{display_name: "林美玲"})
  {:ok, _} = People.add_alias(t, "阿美")
  assert {:linked, %{id: id}} = People.resolve_line_member("U2", "阿美")
  assert id == t.id
end

test "several matches are unsure and recorded" do
  a = student!(%{display_name: "Amy"})
  b = student!(%{display_name: "amy"})
  assert {:unsure, candidates} = People.resolve_line_member("U1", "Amy")
  assert Enum.map(candidates, & &1.id) == [a.id, b.id]
  assert %LineMember{state: "unsure", display_name: "Amy"} = People.get_line_member("U1")
end

test "an inactive single match is unsure" do
  student!(%{display_name: "Amy", active: false})
  assert {:unsure, [_]} = People.resolve_line_member("U1", "Amy")
end

test "a single match linked to another LINE id is unsure" do
  student!(%{display_name: "Amy", line_user_id: "U9"})
  assert {:unsure, [_]} = People.resolve_line_member("U1", "Amy")
end
```

`student!/1` inserts through `People.create_student/1`.

- [ ] **Step 3: Run tests to verify they fail.** Run `mix test test/ganesha/people_test.exs`. Expected: FAIL, `resolve_line_member/2` undefined.

- [ ] **Step 4: Implement** `LineMember`, `matching_students/1`, `get_line_member/1` and `resolve_line_member/2` in `lib/ganesha/people.ex`. Clauses in spec §1 table order. Cases 4–6 run inside `Repo.transaction/1`. If `create_student`/`link_line_user_id` fails on the `line_user_id` unique constraint, or the `unsure` insert hits its unique constraint, re-run the lookup and return `{:known, s}` / `:pending`. Matching loads students with aliases and filters in Elixir (the studio has dozens of students).

- [ ] **Step 5: Run tests to verify they pass.** `mix test test/ganesha/people_test.exs`. Expected: PASS.

- [ ] **Step 6: Commit.** `git add priv/repo/migrations lib/ganesha/people.ex lib/ganesha/people/line_member.ex test/ganesha/people_test.exs && git commit -m "Resolve a LINE group member to a Student by LINE id or name"`

---

### Task 2: Member notices

**Files:**
- Create: `lib/ganesha/assistant/member_notice_worker.ex`
- Create: `lib/ganesha/assistant/group_members.ex` (only `resolve/2` in this task)
- Modify: `lib/ganesha/assistant.ex` (add `teacher_locale/1`), `lib/ganesha/assistant/draft_notifier.ex` (use it; delete its private copy)
- Modify: `lib/ganesha/line/labels.ex`, `lib/ganesha/line/cards.ex`
- Test: `test/ganesha/assistant/member_notice_worker_test.exs`, `test/ganesha/line/cards_test.exs`

**Interfaces:**
- Consumes: `People.resolve_line_member/2`, `People.resolution()` (Task 1).
- Produces:
  - `Assistant.teacher_locale(teacher_id :: String.t()) :: String.t()`: the Teacher chat thread's locale, default `"zh-TW"` (moved from `DraftNotifier`).
  - `GroupMembers.resolve(line_user_id :: String.t(), display_name :: String.t()) :: People.resolution() | :skipped`: `:skipped` for `Line.teacher?/1` ids. Otherwise one `Repo.transaction` running `People.resolve_line_member/2` and, for `created`/`linked`/`unsure`, `Oban.insert(MemberNoticeWorker.new(MemberNoticeWorker.args(result, line_user_id, display_name)))`.
  - `MemberNoticeWorker.args(resolution, line_user_id, display_name) :: map()`: string keys. `"kind"` (`"created" | "linked" | "unsure"`), `"line_user_id"`, `"display_name"`. For created/linked, `"student_id"` and `"student_name"`. For unsure, `"candidates"` (up to 3 `%{"id", "name"}`) and `"more"` (count beyond 3).
  - `Cards.member_notice(args :: map(), locale) :: map()`: a kilo bubble (body text + footer buttons, vertical when more than 2), same shape as `draft_bubble/2`.
  - `Cards.member_postback(action, args, extra \\ []) :: String.t()`: `URI.encode_query/1` of `action`, `uid`, `name` (LINE name truncated to 20 graphemes), plus `from`/`sid` as given.
  - Postback actions: `member_not_student` (`from`, `sid` when from created/linked), `member_wrong_link` (`sid`), `member_pick` (`sid`), `member_new`.

Labels to add (exact copy):

| key | zh-TW | en |
|---|---|---|
| `member_created` | `新增學生 %{name}（LINE：%{line_name}）` | `Added student %{name} (LINE: %{line_name})` |
| `member_linked` | `已把 LINE %{line_name} 連到學生 %{name}` | `Linked LINE %{line_name} to student %{name}` |
| `member_unsure` | `LINE %{line_name} 是哪位學生？` | `Which student is LINE %{line_name}?` |
| `member_more` | `還有 %{count} 位同名，請到網頁處理` | `%{count} more with this name; fix it on the web` |
| `member_not_student` | `不是學生` | `Not a student` |
| `member_wrong_link` | `連錯了` | `Wrong student` |
| `member_new` | `新學生` | `New student` |
| `member_marked_not_student` | `好，LINE %{line_name} 不是學生。` | `OK, LINE %{line_name} is not a student.` |
| `member_kept_records` | `好，LINE %{line_name} 不是學生。學生 %{name} 已有記錄，所以保留並取消連結，請到網頁整理。` | `OK, LINE %{line_name} is not a student. Student %{name} has records, so they were kept and unlinked; tidy them up on the web.` |
| `member_unlinked` | `好，已取消 LINE %{line_name} 的連結，請在下一則訊息選擇。` | `OK, LINE %{line_name} is unlinked; choose in the next message.` |
| `member_already_handled` | `這位成員已經處理過了。` | `This member was already handled.` |

Unsure buttons: one per candidate labelled with the Student's name (`member_pick`), then `member_new`, then `member_not_student` (`from=unsure`). `member_more` is a second body text line when `"more" > 0`. Linked: `member_not_student` (`from=linked`), `member_wrong_link`. Created: `member_not_student` (`from=created`).

- [ ] **Step 1: Write the failing tests.**

`member_notice_worker_test.exs` (`use Ganesha.DataCase`, `use Oban.Testing`):

```elixir
test "pushes the created notice to every teacher in her locale" do
  # teachers @teacher (zh-TW default) and @other_teacher with an "en" Teacher chat thread
  args = %{"kind" => "created", "line_user_id" => "U1", "display_name" => "小美",
           "student_id" => 7, "student_name" => "小美"}
  assert :ok = perform_job(MemberNoticeWorker, args)
  assert [{:push, {@teacher, [zh]}}, {:push, {@other_teacher, [en]}}] = LineMock.calls()
  assert zh.altText == "新增學生 小美（LINE：小美）"
  assert en.altText == "Added student 小美 (LINE: 小美)"
end

test "fails only when every push failed" # stub push to error for all → {:error, _}; one ok → :ok

test "GroupMembers.resolve enqueues one notice for a created student" do
  assert {:created, s} = GroupMembers.resolve("U1", "小美")
  assert_enqueued worker: MemberNoticeWorker,
                  args: %{"kind" => "created", "student_id" => s.id, "line_user_id" => "U1"}
end

test "GroupMembers.resolve skips teachers and enqueues nothing for known or pending" do
  assert :skipped = GroupMembers.resolve(@teacher, "老師")
  # known: student linked to U1 → refute_enqueued; pending: unsure row → refute_enqueued
end
```

The mock push always returns `:ok`. For the failure test, add `Process.get(:line_client_mock_push, :ok)` as `Mock.push/2`'s return value (the same pattern as `:line_client_mock_group_member`), still recording the call.

`cards_test.exs`:

```elixir
test "member notice postback data fits LINE's 300-character limit" do
  name = String.duplicate("瑜", 20)
  args = %{"kind" => "unsure", "line_user_id" => "U" <> String.duplicate("a", 32),
           "display_name" => name, "candidates" => [%{"id" => 123_456, "name" => name}],
           "more" => 0}
  for %{action: %{data: data}} <- footer_buttons(Cards.member_notice(args, "zh-TW")),
      do: assert String.length(data) <= 300
end

test "unsure card lists candidates, then new student, then not a student" do
  # labels in order: candidate names, "新學生", "不是學生"; "more" => 2 adds "還有 2 位同名，請到網頁處理"
end
```

- [ ] **Step 2: Run tests to verify they fail.** `mix test test/ganesha/assistant/member_notice_worker_test.exs test/ganesha/line/cards_test.exs`. Expected: FAIL, modules and functions undefined.

- [ ] **Step 3: Implement** `Assistant.teacher_locale/1` (and switch `DraftNotifier`), the Labels, `Cards.member_notice/2`, `Cards.member_postback/3`, `MemberNoticeWorker` (`use Oban.Worker, queue: :default, max_attempts: 3`) and `GroupMembers.resolve/2`. Each push is `[Client.flex_message(alt_text, Cards.member_notice(args, locale))]`, where `alt_text` is the notice's first text line. Success follows `DraftNotifier.push_and_mark/2`: `:ok` if any push returned `:ok`, else the first error (`{:error, :no_teachers}` with no teachers).

- [ ] **Step 4: Run tests to verify they pass.** Same command; also `mix test test/ganesha/assistant/draft_notifier_test.exs`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -m "Notify teachers when a group member becomes, or might be, a Student"` (stage the files above).

---

### Task 3: Resolve in the group pipeline and tag senders

**Files:**
- Modify: `lib/ganesha/assistant/process_event_worker.ex` (`route/1`, `handle_group_message/3`, `run_group_agent/1`)
- Modify: `lib/ganesha/assistant/group_members.ex` (add `tag_history/1`)
- Modify: `lib/ganesha/assistant/prompts.ex` (`group/0`)
- Modify: `GLOSSARY.md`
- Test: `test/ganesha/assistant/process_event_worker_test.exs`

**Interfaces:**
- Consumes: `GroupMembers.resolve/2` (Task 2), `People.get_line_member/1`, `People.find_by_line_user_id/1`.
- Produces: `GroupMembers.tag_history([Assistant.Message.t()]) :: [Assistant.Message.t()]`. User messages with a non-nil `sender_id` and `content` get `content` prefixed with the tag and one space. Tags: `[student <id> <display_name>]`, `[LINE <sender_name>, not a student]`, `[LINE <sender_name>, unmatched]` (unsure or unresolved; `sender_name` nil → `[LINE unknown, unmatched]`). Lookups are one query per kind for all sender ids, not per message.

- [ ] **Step 1: Write the failing tests** in the group `describe` of `process_event_worker_test.exs` (helpers `deliver/1`, `group_text/2`, `group_source/1` exist):

```elixir
test "an unknown sender becomes a student before the turn, and the turn sees the tag" do
  Process.put(:line_client_mock_group_member, {:ok, %{"displayName" => "小美"}})
  Mock.stub(fn messages, _tools, _opts ->
    send(self(), {:wire, messages}); {:ok, %{text: "ok", tool_calls: []}}
  end)
  {:ok, _} = deliver(group_text("Ustudent1", "已轉帳1600"))
  s = People.find_by_line_user_id("Ustudent1")
  assert s.display_name == "小美"
  assert_received {:wire, [%{role: "user", content: content} | _]}
  assert content == "[student #{s.id} 小美] 已轉帳1600"
  assert_enqueued worker: MemberNoticeWorker, args: %{"kind" => "created"}
  {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
  assert [%{content: "已轉帳1600"} | _] = Assistant.list_messages(thread)
  assert LineMock.calls() == []
end

test "memberJoined then a message creates one student and one notice" do
  joined = %{"type" => "memberJoined", "source" => %{"type" => "group", "groupId" => "Cabc"},
             "joined" => %{"members" => [%{"type" => "user", "userId" => "Unew"}]}}
  {:ok, _} = deliver(joined)
  {:ok, _} = deliver(group_text("Unew", "大家好"))
  assert Repo.aggregate(People.Student, :count) == 1
  assert length(all_enqueued(worker: MemberNoticeWorker)) == 1
end

test "a not_student member is never created and is tagged as such"
# insert LineMember not_student for "Uhusband", displayName "老公" → no Student; wire content starts "[LINE 老公, not a student] "

test "a teacher posting with dev_teacher_posts_in_groups on is not resolved"
# put_env :dev_teacher_posts_in_groups true (restore on_exit) → no Student, no MemberNoticeWorker job

test "memberJoined in a blocked group, or of a blocked sender, resolves nothing"

test "a failed member lookup resolves nothing and still runs the agent"
# extend the existing "a failed member lookup..." test: no Student, refute_enqueued MemberNoticeWorker
```

- [ ] **Step 2: Run tests to verify they fail.** `mix test test/ganesha/assistant/process_event_worker_test.exs`. Expected: the new tests FAIL.

- [ ] **Step 3: Implement.**
  - `handle_group_message/3`: look up `sender_name` once. When both id and name are non-nil, call `GroupMembers.resolve/2` before `append_message`. Pass the same name to `append_message`.
  - New `route/1` clause for `%{source_type: "group", raw_type: "memberJoined"}`: skip when `Line.blocked?("group", group_id)`. For each `payload["joined"]["members"]` with a `"userId"`: skip blocked senders, look up the name, and resolve when the name is non-nil. Return `:ok`.
  - `run_group_agent/1`: `Agent.run(thread, Tasks.for_chat(:group), system, thread |> Assistant.list_messages() |> GroupMembers.tag_history())`.
  - `Prompts.group/0`: replace "If you cannot tell which student or which Session it is, propose nothing; never guess." with the spec §1 paragraph ("Each student message starts with a tag naming who sent it. When the message is about the sender, use the student id in the tag. A tag without a student id means the sender is not a known student: propose nothing for them unless the message names a student in the snapshot."), followed by "If you cannot tell which Session it is, propose nothing; never guess."
  - `GLOSSARY.md`: under the LINE terms, add **Group member** with the spec's definition and `_Avoid_: group user, participant`.
  - Update existing tests that break because group senders now become Students (e.g. Student counts, provider-stub content matches). Keep their intent; don't delete assertions about never sending into the group.

- [ ] **Step 4: Run tests to verify they pass.** `mix test test/ganesha/assistant/`. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -m "Resolve group members as they post or join and tell the model who sent each message"`

---

### Task 4: The teacher's taps

**Files:**
- Modify: `lib/ganesha/people.ex`
- Modify: `lib/ganesha/assistant/conversation.ex` (`handle_postback/3`)
- Test: `test/ganesha/people_test.exs`, `test/ganesha/assistant/conversation_test.exs`

**Interfaces:**
- Consumes: postback params from `Cards.member_postback/3`, `MemberNoticeWorker.args/3`, `GroupMembers` notice enqueue (Task 2), and `People.matching_students/1` (Task 1).
- Produces, in `People` (each runs in one transaction; `{:error, :already_handled}` when the state no longer matches the "expects" column of spec §2):
  - `member_not_student(line_user_id, display_name, from :: "created" | "linked" | "unsure", student_id :: integer() | nil) :: {:ok, :marked} | {:ok, {:kept, Student.t()}} | {:error, :already_handled}`. From created: delete the Student when they have no purchases, attendances or credits (`:marked`), else clear `line_user_id` (`{:kept, s}`). From linked: clear `line_user_id` (`:marked`). From unsure: row → `not_student`. Created and linked also insert the `not_student` row.
  - `member_wrong_link(line_user_id, display_name, student_id) :: {:ok, [Student.t()]} | {:error, :already_handled}`: clear `line_user_id`, insert the `unsure` row, return `matching_students(display_name)`.
  - `member_pick(line_user_id, student_id) :: {:ok, Student.t()} | {:error, :already_handled}`: requires the `unsure` row and an active, unlinked `student_id`.
  - `member_new(line_user_id, display_name) :: {:ok, Student.t()} | {:error, :already_handled}`: requires the `unsure` row.
- `Conversation.handle_postback/3`: new clause for actions `member_not_student | member_wrong_link | member_pick | member_new`, teacher only (else `unknown_action/2`). Each replies with one text message through `deliver/4`: `member_marked_not_student`, `member_kept_records`, `member_unlinked` (and enqueues an unsure notice via `MemberNoticeWorker.args({:unsure, candidates}, uid, name)`), `member_linked`, `member_created`, or `member_already_handled`. No history line is appended.

- [ ] **Step 1: Write the failing tests.**

`people_test.exs`, `describe "member taps"`: one test per row of the spec §2 table, plus:

```elixir
test "not a student from created keeps a student who has records" do
  {:created, s} = People.resolve_line_member("U1", "小美")
  purchase_for!(s)   # existing fixture helper pattern in people/sales tests
  assert {:ok, {:kept, %{id: id, line_user_id: nil}}} =
           People.member_not_student("U1", "小美", "created", s.id)
  assert id == s.id
  assert %LineMember{state: "not_student"} = People.get_line_member("U1")
end

test "a tap on a member already handled changes nothing" do
  Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})
  {:ok, _} = People.member_new("U1", "Amy")
  assert {:error, :already_handled} = People.member_pick("U1", 1)
  assert {:error, :already_handled} = People.member_new("U1", "Amy")
end
```

`conversation_test.exs`:

```elixir
test "a teacher's member_new tap creates the student and replies" do
  # unsure row for U1/Amy; handle_postback(%{"action" => "member_new", "uid" => "U1", "name" => "Amy"}, "rt", @teacher)
  # → reply text Labels.t(:member_created, "zh-TW", name: "Amy", line_name: "Amy")
end

test "a non-teacher's member tap is refused" # → unknown_action reply, nothing changes

test "member_wrong_link replies and enqueues a fresh unsure notice" # assert_enqueued kind "unsure"

test "the second teacher's tap gets member_already_handled"
```

- [ ] **Step 2: Run tests to verify they fail.** `mix test test/ganesha/people_test.exs test/ganesha/assistant/conversation_test.exs`. Expected: new tests FAIL.

- [ ] **Step 3: Implement** the four `People` functions and the `Conversation.handle_postback/3` clause (`parse_id/1` for `sid`). The "has records" check is `exists?` on `Purchase`, `Attendance` and `Credit` by `student_id`; aliases cascade and Drafts nilify on delete.

- [ ] **Step 4: Run tests to verify they pass.** Same command. Expected: PASS.

- [ ] **Step 5: Commit.** `git commit -m "Let teachers correct a group member's Student from the notice"`

---

### Task 5: Offline smoke and precommit

**Files:**
- Modify: `priv/scripts/line_smoke.exs`

- [ ] **Step 1: Extend the smoke script** with steps after the existing last step, using its existing mocks and helpers. Step A: a group message from a new LINE id `U_smoke_member` named `小新` creates Student 小新 and enqueues one `MemberNoticeWorker` job. Run that job and print the pushed alt text (`新增學生 小新（LINE：小新）`). Step B: a `member_not_student` postback with `from=created` deletes the Student and leaves a `not_student` row. Step C: the same LINE id posting again creates nothing.

- [ ] **Step 2: Run it.** `mix run priv/scripts/line_smoke.exs`. Expected: every step prints OK, including A–C.

- [ ] **Step 3: Run** `mix precommit`. Expected: compiles with no warnings, formatted, all tests pass.

- [ ] **Step 4: Commit.** `git commit -m "Smoke-test group member resolution offline"`

---

### Task 6: Launch (spec §3)

Human-gated: run each step of the spec §3 checklist in order. Steps marked Mickey or teacher are his or hers to do; wait for them to confirm before moving on. Never wipe the prod volume (step 6) without Mickey's explicit yes in that moment.

- [ ] **Step 1:** Mickey: new Anthropic key in `.env.dev`. Run `mix run priv/scripts/line_real_turn.exs` and check that the Haiku 5.5 turn proposes a sensible Draft.
- [ ] **Step 2:** Mickey: Official Account created, channel secret and token ready, auto-reply and greeting off, groups allowed, plan and push quota noted.
- [ ] **Step 3:** Mickey: `flyctl auth login`. Then `fly secrets list -a ganesha` and `fly ssh console -a ganesha -C "ls -la /data"`; report what exists.
- [ ] **Step 4:** `fly secrets set` the LINE values, `TEACHER_LINE_USER_ID` and `ANTHROPIC_API_KEY`; `fly secrets unset ANTHROPIC_MODEL` if present.
- [ ] **Step 5:** `fly storage create` (Tigris), then set the four `LITESTREAM_*` secrets from its output.
- [ ] **Step 6:** With Mickey's yes, wipe old data if present. Then `fly deploy`. Expected: the machine boots, `fly logs` shows migrations and no "LITESTREAM_BUCKET not set" line.
- [ ] **Step 7:** Seed the login in the running node: `fly ssh console -a ganesha -C "/app/bin/ganesha rpc 'System.put_env(\"TEACHER_EMAIL\", \"<email>\"); System.put_env(\"TEACHER_PASSWORD\", \"<password>\"); Code.eval_file(Application.app_dir(:ganesha, \"priv/repo/seeds.exs\"))'"`, with Mickey's values. Check that `curl -fsS https://ganesha.fly.dev/health` answers and the teacher logs in on her phone.
- [ ] **Step 8:** Mickey: webhook URL `https://ganesha.fly.dev/line/webhook`, Use webhook on, Verify succeeds.
- [ ] **Step 9:** Teacher: 1:1 message to the bot gets a Teacher chat reply.
- [ ] **Step 10:** Mickey adds the bot to the student group. The first member post sends the teachers a 新增學生 notice; check `fly logs` for errors.
- [ ] **Step 11:** Teacher: November Slots and Packages created in the Teacher chat before 1 Nov.
- [ ] **Step 12:** Mickey decides whether to tell the students.
