# Student Sign-up Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When someone asks to sign up for a class in a Student chat, record an acknowledge-only Draft, push its card to every teacher's 1:1 chat after 5 quiet minutes, and let a teacher tap 「幫他報名」 to start `enroll` (or `add_student` first) in her own chat.

**Architecture:** A new `:change` task `signup_request` joins `set_language` in Student chats; Student-chat replies drop Draft cards. `GroupDraftNotifier` becomes `DraftNotifier`, keyed by thread, with group timing unchanged and a debounced 5-minute timing for Student chats. A third card button posts `action=enroll_from_request`, which `Conversation` turns into a confirmed request plus a normal Teacher-chat turn.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Ecto + ecto_sqlite3, Oban 2.24.1 (`Oban.Engines.Lite`), Req, LINE Messaging API.

**Spec:** `docs/superpowers/specs/2026-10-06-student-signup-request-design.md`

## Global Constraints

- Student chats never see studio data: no times, dates, prices or availability (spec Decision 2).
- The student never sees a Draft card; their reply text stays the model's own (spec §2).
- Group notifier timing is unchanged: 3 minutes from the first Draft (spec §3).
- Student-chat notifier: `schedule_in: 300`, `unique: [period: :infinity, keys: [:thread_id], states: [:available, :scheduled]]`, `replace: [scheduled: [:scheduled_at]]` (spec §3; verified on Oban 2.24.1 Lite, 2026-10-06).
- Only a teacher (`Ganesha.Line.teacher?/1`) may use 確認, 捨棄 or 「幫他報名」 (spec §5).
- No compatibility module for `GroupDraftNotifier` (spec §3).
- Tests: `use Ganesha.DataCase`; `Ganesha.Line.Client.Mock` is the configured client; `Ganesha.Assistant.Provider.Mock.stub/1` drives the model. No `Process.sleep`.
- Finish with `mix precommit` (AGENTS.md) and the smoke script.

---

### Task 1: `get_profile/1` on the LINE client

**Files:**
- Modify: `lib/ganesha/line/client_behaviour.ex`
- Modify: `lib/ganesha/line/client.ex:47-49`
- Modify: `lib/ganesha/line/client/mock.ex:39-43`
- Modify: `test/ganesha/assistant/conversation_test.exs:14-56` (three stub modules)
- Modify: `test/ganesha/assistant/group_draft_notifier_test.exs:53-69` (one stub module)
- Test: `test/ganesha/line/client_test.exs`

**Interfaces:**
- Produces: `@callback get_profile(user_id :: String.t()) :: {:ok, map()} | {:error, term()}`; `Ganesha.Line.Client.get_profile/1` (GET `/v2/bot/profile/{userId}`); `Ganesha.Line.Client.Mock.get_profile/1` returning `Process.get(:line_client_mock_profile, {:ok, %{"displayName" => "測試新朋友"}})` and recording `{:profile, user_id}` in `lookups/0`.

- [ ] **Step 1: Write the failing test**

Append to `test/ganesha/line/client_test.exs`, before the final `end`:

```elixir
  test "get_profile/1 fetches a 1:1 user's display name" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      send(parent, {:request, conn.method, conn.request_path})
      Req.Test.json(conn, %{"userId" => "Uabc", "displayName" => "小美"})
    end)

    assert {:ok, %{"displayName" => "小美"}} = Client.get_profile("Uabc")
    assert_receive {:request, "GET", "/v2/bot/profile/Uabc"}
  end
```

- [ ] **Step 2: Run the test to make sure it fails**

Run: `mix test test/ganesha/line/client_test.exs`
Expected: FAIL with `UndefinedFunctionError ... Ganesha.Line.Client.get_profile/1`

- [ ] **Step 3: Implement**

`lib/ganesha/line/client_behaviour.ex`, after the `get_group_summary` callback:

```elixir
  @callback get_profile(user_id :: String.t()) :: {:ok, map()} | {:error, term()}
```

`lib/ganesha/line/client.ex`, after `get_group_summary/1`:

```elixir
  @doc "A 1:1 user's display name and picture; read-only (spec 2026-10-06 §4)."
  @impl true
  def get_profile(user_id), do: get("/v2/bot/profile/#{user_id}")
```

`lib/ganesha/line/client/mock.ex`, after `get_group_summary/1`:

```elixir
  @impl true
  def get_profile(user_id) do
    record_lookup({:profile, user_id})
    Process.get(:line_client_mock_profile, {:ok, %{"displayName" => "測試新朋友"}})
  end
```

Every test module that implements the behaviour must forward the new callback, or it stops compiling cleanly. In `test/ganesha/assistant/conversation_test.exs`, add this line to each of `ExpiredTokenLine`, `RejectingLine` and `InterleavingLine`, after their `get_group_summary` line:

```elixir
    def get_profile(user_id), do: LineMock.get_profile(user_id)
```

In `test/ganesha/assistant/group_draft_notifier_test.exs`, inside `PushFailClient`, after `get_group_summary`:

```elixir
      def get_profile(user_id), do: Ganesha.Line.Client.Mock.get_profile(user_id)
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `mix test test/ganesha/line test/ganesha/assistant/conversation_test.exs test/ganesha/assistant/group_draft_notifier_test.exs`
Expected: PASS, no "required by behaviour" warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/line/client_behaviour.ex lib/ganesha/line/client.ex lib/ganesha/line/client/mock.ex test/ganesha/line/client_test.exs test/ganesha/assistant/conversation_test.exs test/ganesha/assistant/group_draft_notifier_test.exs
git commit -m "Add LINE get_profile/1 for 1:1 display names"
```

---

### Task 2: The `signup_request` task in Student chats

**Files:**
- Create: `lib/ganesha/assistant/tasks/signup_request.ex`
- Modify: `lib/ganesha/assistant/tasks.ex:9-37,65` (alias, `@student`)
- Modify: `lib/ganesha/assistant/prompts.ex:22-39` (student prompts)
- Modify: `test/ganesha/assistant/tasks_test.exs:6-34,50-52`
- Modify: `test/ganesha/assistant/conversation_test.exs:169-180`
- Modify: `GLOSSARY.md` (after **Discard**)
- Modify: `docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md:38-40,85`
- Test: `test/ganesha/assistant/tasks/signup_request_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Line.Client.Mock.get_profile/1` (Task 1); `Ganesha.People.find_by_line_user_id/1`.
- Produces: `Ganesha.Assistant.Tasks.SignupRequest` with `name/0 == "signup_request"`, `kind/0 == :change`, `propose/2`, `apply/2`, `summary/2`. `parsed` keys: `"note"`, `"student_id"`, `"student_name"`, `"line_user_id"`, `"line_name"`, `"new"` (boolean). `Tasks.for_chat(:student) == [SetLanguage, SignupRequest]`.

- [ ] **Step 1: Write the failing tests**

Create `test/ganesha/assistant/tasks/signup_request_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.SignupRequestTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.Tasks.SignupRequest
  alias Ganesha.Line.Client.Mock, as: LineMock

  defp ctx(line_user_id) do
    {:ok, thread} = Assistant.get_or_create_thread("user", line_user_id)
    %{thread: thread, locale: "zh-TW", today: ~D[2026-10-06]}
  end

  test "a linked student is named from the ledger, without asking LINE" do
    {:ok, student} = People.create_student(%{display_name: "Amy", line_user_id: "Uamy"})

    assert {:ok, %{student_id: student_id, parsed: parsed}} =
             SignupRequest.propose(%{"note" => " 想報名週一晚上 "}, ctx("Uamy"))

    assert student_id == student.id

    assert parsed == %{
             "note" => "想報名週一晚上",
             "student_id" => student.id,
             "student_name" => "Amy",
             "line_user_id" => "Uamy",
             "line_name" => nil,
             "new" => false
           }

    assert LineMock.lookups() == []
  end

  test "anyone else is a newcomer named by their LINE profile" do
    Process.put(:line_client_mock_profile, {:ok, %{"displayName" => "小美"}})

    assert {:ok, %{student_id: nil, parsed: parsed}} =
             SignupRequest.propose(%{"note" => "想報名"}, ctx("Unewcomer"))

    assert %{"new" => true, "line_user_id" => "Unewcomer", "line_name" => "小美"} = parsed
    assert LineMock.lookups() == [{:profile, "Unewcomer"}]
  end

  @tag :capture_log
  test "a failed profile lookup leaves the newcomer unnamed" do
    Process.put(:line_client_mock_profile, {:error, {404, %{}}})

    assert {:ok, %{parsed: %{"new" => true, "line_name" => nil}}} =
             SignupRequest.propose(%{"note" => "想報名"}, ctx("Unewcomer2"))
  end

  test "rejects a blank or missing note" do
    assert {:error, message} = SignupRequest.propose(%{"note" => "  "}, ctx("Ublank"))
    assert message =~ "needs a note"
    assert {:error, _} = SignupRequest.propose(%{}, ctx("Ublank"))
  end

  test "confirming only acknowledges it" do
    assert {:ok, {nil, nil}} = SignupRequest.apply(%{"note" => "想報名"}, "line:teacher")
  end

  test "the summary names the student, else the newcomer's LINE name, else neither" do
    student = %{"new" => false, "student_name" => "Amy", "note" => "週一晚上"}
    named = %{"new" => true, "line_name" => "小美", "note" => "週一晚上"}
    unnamed = %{"new" => true, "line_name" => nil, "note" => "週一晚上"}

    for locale <- ["zh-TW", "en"] do
      assert SignupRequest.summary(student, locale) =~ "Amy"
      assert SignupRequest.summary(named, locale) =~ "小美"
      assert SignupRequest.summary(unnamed, locale) =~ "週一晚上"
    end
  end
end
```

In `test/ganesha/assistant/tasks_test.exs`, add `SignupRequest,` to the alias list (between `SetSessionStyle,` and `StudentSummary,`), change line 52 to:

```elixir
    assert Tasks.for_chat(:student) == [SetLanguage, SignupRequest]
```

and append before the final `end`:

```elixir
  test "signup_request is Student chat only" do
    assert SignupRequest in Tasks.for_chat(:student)
    refute SignupRequest in Tasks.for_chat(:teacher)
    refute SignupRequest in Tasks.for_chat(:group)
  end
```

In `test/ganesha/assistant/conversation_test.exs`, rename the test at line 169 and change its tool assertion:

```elixir
    test "a Student chat gets set_language and signup_request, and no snapshot" do
```

```elixir
      assert Enum.map(request.tools, & &1.name) == ["set_language", "signup_request"]
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/assistant/tasks/signup_request_test.exs test/ganesha/assistant/tasks_test.exs test/ganesha/assistant/conversation_test.exs`
Expected: FAIL (`module Ganesha.Assistant.Tasks.SignupRequest is not available`).

- [ ] **Step 3: Write the task**

Create `lib/ganesha/assistant/tasks/signup_request.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.SignupRequest do
  @moduledoc """
  `signup_request` (spec 2026-10-06 §1): someone in a Student chat asked to
  sign up for a class. The Draft is acknowledged only; confirming books
  nothing. The teacher enrolls them herself, or through 「幫他報名」.

  Who asked comes from the Student chat, never from the model: the student
  linked to the chat's LINE user id, or else a newcomer named by their LINE
  profile.
  """
  @behaviour Ganesha.Assistant.Task

  require Logger

  alias Ganesha.People

  @impl true
  def name, do: "signup_request"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      The person wants to sign up for a class. Pass on what they asked for in their own \
      words so the teacher can follow up. You cannot see the timetable or prices; never \
      add a time, date or price they did not say.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          note: %{
            type: "string",
            description: "What they asked for, e.g. 想報名週一晚上的課，11月開始"
          }
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def propose(input, %{thread: %{source_id: line_user_id}}) do
    with {:ok, note} <- fetch_note(input["note"]) do
      {:ok, asker(line_user_id, note)}
    end
  end

  @impl true
  def apply(_parsed, _confirmed_by), do: {:ok, {nil, nil}}

  @impl true
  def summary(%{"new" => false} = parsed, "en"),
    do: "#{parsed["student_name"]} wants to sign up: #{parsed["note"]}"

  def summary(%{"new" => false} = parsed, _locale),
    do: "#{parsed["student_name"]} 想報名：#{parsed["note"]}"

  def summary(%{"line_name" => name} = parsed, "en") when is_binary(name),
    do: "Newcomer (LINE: #{name}) wants to sign up: #{parsed["note"]}"

  def summary(parsed, "en"), do: "A newcomer wants to sign up: #{parsed["note"]}"

  def summary(%{"line_name" => name} = parsed, _locale) when is_binary(name),
    do: "新朋友（LINE：#{name}）想報名：#{parsed["note"]}"

  def summary(parsed, _locale), do: "新朋友想報名：#{parsed["note"]}"

  defp asker(line_user_id, note) do
    case People.find_by_line_user_id(line_user_id) do
      %People.Student{} = student ->
        %{
          student_id: student.id,
          parsed: %{
            "note" => note,
            "student_id" => student.id,
            "student_name" => student.display_name,
            "line_user_id" => line_user_id,
            "line_name" => nil,
            "new" => false
          }
        }

      nil ->
        %{
          student_id: nil,
          parsed: %{
            "note" => note,
            "student_id" => nil,
            "student_name" => nil,
            "line_user_id" => line_user_id,
            "line_name" => line_name(line_user_id),
            "new" => true
          }
        }
    end
  end

  defp line_name(line_user_id) do
    case line_client().get_profile(line_user_id) do
      {:ok, %{"displayName" => name}} when is_binary(name) and name != "" ->
        name

      other ->
        Logger.warning("LINE profile lookup failed for #{line_user_id}: #{inspect(other)}")
        nil
    end
  end

  defp fetch_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> {:error, missing_note()}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_note(_note), do: {:error, missing_note()}

  defp missing_note, do: "signup_request needs a note saying what the person asked for"

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
```

- [ ] **Step 4: Register it and update the student prompts**

`lib/ganesha/assistant/tasks.ex`: add `SignupRequest,` to the alias list (after `SetSessionStyle,`) and change line 65 to:

```elixir
  @student [SetLanguage, SignupRequest]
```

`lib/ganesha/assistant/prompts.ex`, replace both `student/1` clauses (lines 22-39) with:

```elixir
  def student("en") do
    """
    You are a helpful assistant for this yoga studio's LINE account. Reply in English. \
    Be brief and friendly. You have no access to the studio's schedule, prices, class \
    availability, bookings, or anyone's class credits. Never state or guess times, dates, \
    prices, or availability. When asked about any of these, say the teacher will reply \
    personally. When the person asks to sign up for a class, call signup_request with what \
    they asked for in their own words, then say the teacher will reply personally. If the \
    person asks to switch language, call set_language.
    """
  end

  def student(_locale) do
    """
    你是這間瑜珈教室 LINE 官方帳號的助理。只用繁體中文回覆，語氣簡短友善。\
    你看不到教室的課表、價格、名額、預約或任何人的堂數。絕對不要說出或猜測\
    上課時間、日期、價格或名額；被問到這些時，告訴對方老師會親自回覆。\
    對方想報名課程時，呼叫 signup_request，把對方說的內容照原話填進 note，\
    然後告訴對方老師會親自回覆。對方想換語言時，呼叫 set_language。
    """
  end
```

- [ ] **Step 5: Update the glossary and the base spec**

`GLOSSARY.md`, after the **Discard** entry:

```markdown

**Sign-up request**:
A Draft from a Student chat recording that someone asked to sign up for a class; Confirm acknowledges it and books nothing.
_Avoid_: enrollment request, registration
```

`docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md`, replace rule 7's last sentence (lines 39-40, "Student chats get none (only `set_language`).") with:

```markdown
   single-class/trial booking, makeup request. Student chats get `set_language`
   and `signup_request` (`2026-10-06-student-signup-request-design.md`).
```

and on line 85 remove ", tools for Student chats" so it ends at "posting in the Group chat.".

- [ ] **Step 6: Run the tests to make sure they pass**

Run: `mix test test/ganesha/assistant`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/ganesha/assistant/tasks/signup_request.ex lib/ganesha/assistant/tasks.ex lib/ganesha/assistant/prompts.ex test/ganesha/assistant/tasks/signup_request_test.exs test/ganesha/assistant/tasks_test.exs test/ganesha/assistant/conversation_test.exs GLOSSARY.md docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md
git commit -m "Add signup_request to Student chats"
```

---

### Task 3: Student chats reply with text only

**Files:**
- Modify: `lib/ganesha/assistant/conversation.ex:31-37` and add a private helper
- Test: `test/ganesha/assistant/conversation_test.exs` (`describe "handle_message/3"`)

**Interfaces:**
- Consumes: `signup_request` (Task 2).
- Produces: `Conversation.handle_message/3` sends Student chats `turn.text` only; no Draft carousel and no card lines recorded.

- [ ] **Step 1: Write the failing test**

In `test/ganesha/assistant/conversation_test.exs`, add inside `describe "handle_message/3"`, after the Student chat test:

```elixir
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
```

- [ ] **Step 2: Run the test to make sure it fails**

Run: `mix test test/ganesha/assistant/conversation_test.exs`
Expected: the new test FAILS: the reply carries a flex carousel and the last message has a card line appended.

- [ ] **Step 3: Implement**

In `lib/ganesha/assistant/conversation.ex`, change line 33:

```elixir
        drafts = cards_for(thread, turn)
```

and add next to `text_only/3`:

```elixir
  # Spec 2026-10-06 §2: a Student chat never sees Draft cards; its Drafts reach
  # the teachers through DraftNotifier instead.
  defp cards_for(%Thread{source_type: "user"}, _turn), do: []
  defp cards_for(_thread, %Turn{draft_ids: ids}), do: Assistant.get_drafts(ids)
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `mix test test/ganesha/assistant/conversation_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/conversation.ex test/ganesha/assistant/conversation_test.exs
git commit -m "Student chats never get Draft cards"
```

---

### Task 4: `DraftNotifier` for Group and Student chats

**Files:**
- Rename: `lib/ganesha/assistant/group_draft_notifier.ex` → `lib/ganesha/assistant/draft_notifier.ex`
- Rename: `test/ganesha/assistant/group_draft_notifier_test.exs` → `test/ganesha/assistant/draft_notifier_test.exs`
- Modify: `lib/ganesha/line/labels.ex:38-40` (new intro label)
- Modify: `lib/ganesha/assistant/process_event_worker.ex:21-29,121,180-207`
- Modify: `lib/ganesha/assistant/conversation.ex:17,22-48`
- Modify: `lib/ganesha/assistant.ex:245-249` (doc)
- Modify: `test/ganesha/assistant/process_event_worker_test.exs:6,236,255,264` and add tests
- Modify: `priv/scripts/line_smoke.exs:24-25,36-39,117-143,905-918`

**Interfaces:**
- Consumes: `signup_request` Drafts (Task 2); `Labels.t/3`.
- Produces: `Ganesha.Assistant.DraftNotifier` with `perform/1` on args `%{"thread_id" => id}`, `schedule(Thread.t()) :: {:ok, Oban.Job.t()} | {:error, term()}` (group and `"user"` threads only), `schedule_if_pending(Thread.t()) :: :ok`. Label `:student_drafts_push_intro`.

- [ ] **Step 1: Move the files**

```bash
git mv lib/ganesha/assistant/group_draft_notifier.ex lib/ganesha/assistant/draft_notifier.ex
git mv test/ganesha/assistant/group_draft_notifier_test.exs test/ganesha/assistant/draft_notifier_test.exs
```

- [ ] **Step 2: Write the failing tests**

Replace the whole of `test/ganesha/assistant/draft_notifier_test.exs` with:

```elixir
defmodule Ganesha.Assistant.DraftNotifierTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  import Ecto.Query

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Draft, DraftNotifier}
  alias Ganesha.Line.Client.Mock, as: LineMock
  alias Ganesha.Line.Labels

  @teacher "Uteacher0000000000000000000000"
  @other_teacher "Uteacher2000000000000000000000"
  @group_id "Cgroupnotify000000000000000"
  @student_line_id "Ustudentnotify0000000000000000"

  setup do
    Application.put_env(:ganesha, :line_client, LineMock)
    {:ok, _} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, group} = Assistant.get_or_create_thread("group", @group_id)
    {:ok, student_chat} = Assistant.get_or_create_thread("user", @student_line_id)
    %{group: group, student_chat: student_chat}
  end

  defp group_draft!(group, attrs \\ %{}) do
    parsed = Map.merge(%{"note" => "8/17"}, attrs)
    {:ok, draft} = Assistant.create_draft(group, %{kind: "makeup_request", parsed: parsed})
    draft
  end

  defp signup_draft!(student_chat) do
    {:ok, draft} =
      Assistant.create_draft(student_chat, %{
        kind: "signup_request",
        parsed: %{
          "note" => "想報名週一晚上",
          "student_id" => nil,
          "student_name" => nil,
          "line_user_id" => @student_line_id,
          "line_name" => "小美",
          "new" => true
        }
      })

    draft
  end

  defp intros do
    for {:push, {to, [%{text: text} | _]}} <- LineMock.calls(), into: %{}, do: {to, text}
  end

  test "pushes a group's unnotified drafts to every teacher, each in her language", %{
    group: group
  } do
    draft = group_draft!(group)
    {:ok, other} = Assistant.get_or_create_thread("teacher", @other_teacher)
    {:ok, _} = Assistant.set_locale(other, "en")
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(DraftNotifier, %{"thread_id" => group.id})

    assert intros() == %{
             @teacher => Labels.t(:group_drafts_push_intro, "zh-TW"),
             @other_teacher => Labels.t(:group_drafts_push_intro, "en")
           }

    assert Enum.all?(LineMock.calls(), fn {:push, {_to, messages}} -> length(messages) == 2 end)
    assert Repo.reload!(draft).notified_at != nil
  end

  test "pushes a Student chat's sign-up request to every teacher with the student intro", %{
    student_chat: student_chat
  } do
    draft = signup_draft!(student_chat)
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(DraftNotifier, %{"thread_id" => student_chat.id})

    assert intros() == %{
             @teacher => Labels.t(:student_drafts_push_intro, "zh-TW"),
             @other_teacher => Labels.t(:student_drafts_push_intro, "zh-TW")
           }

    assert Repo.reload!(draft).notified_at != nil
  end

  test "push failure leaves notified_at nil" do
    defmodule PushFailClient do
      @behaviour Ganesha.Line.ClientBehaviour

      def reply(reply_token, messages),
        do: Ganesha.Line.Client.Mock.reply(reply_token, messages)

      def push(_to, _messages), do: {:error, :api_error}
      def loading(chat_id, seconds), do: Ganesha.Line.Client.Mock.loading(chat_id, seconds)

      def validate_reply(messages), do: Ganesha.Line.Client.Mock.validate_reply(messages)

      def get_group_member(group_id, user_id),
        do: Ganesha.Line.Client.Mock.get_group_member(group_id, user_id)

      def get_group_summary(group_id),
        do: Ganesha.Line.Client.Mock.get_group_summary(group_id)

      def get_profile(user_id), do: Ganesha.Line.Client.Mock.get_profile(user_id)
    end

    {:ok, group} = Assistant.get_or_create_thread("group", "Cfailgroup00000000000000")
    draft = group_draft!(group)
    Application.put_env(:ganesha, :line_client, PushFailClient)

    assert {:error, :api_error} = perform_job(DraftNotifier, %{"thread_id" => group.id})

    assert is_nil(Repo.reload!(draft).notified_at)
    Application.put_env(:ganesha, :line_client, LineMock)
  end

  test "a group keeps one job for three minutes from its first draft", %{group: group} do
    assert {:ok, job1} = DraftNotifier.schedule(group)
    assert {:ok, job2} = DraftNotifier.schedule(group)

    assert job1.id == job2.id
    assert_in_delta DateTime.diff(job1.scheduled_at, DateTime.utc_now()), 180, 5
    stored = Repo.get!(Oban.Job, job1.id).scheduled_at
    assert_in_delta DateTime.diff(stored, job1.scheduled_at), 0, 1
  end

  test "a Student chat's next draft moves its waiting job to five minutes from now", %{
    student_chat: student_chat
  } do
    assert {:ok, job1} = DraftNotifier.schedule(student_chat)

    # Pretend the first draft came four minutes ago.
    soon = DateTime.add(DateTime.utc_now(), 60, :second)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job1.id), set: [scheduled_at: soon])

    assert {:ok, job2} = DraftNotifier.schedule(student_chat)

    assert job2.id == job1.id
    moved = Repo.get!(Oban.Job, job1.id).scheduled_at
    assert_in_delta DateTime.diff(moved, DateTime.utc_now()), 300, 5
  end

  test "a Student chat gets a new job once the waiting one has started", %{
    student_chat: student_chat
  } do
    assert {:ok, job1} = DraftNotifier.schedule(student_chat)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job1.id), set: [state: "executing"])

    assert {:ok, job2} = DraftNotifier.schedule(student_chat)
    assert job2.id != job1.id
  end

  test "schedule_if_pending/1 schedules only when a draft is waiting for the teachers", %{
    student_chat: student_chat
  } do
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    refute_enqueued(worker: DraftNotifier)

    signup_draft!(student_chat)
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => student_chat.id})
  end

  test "pushes 12 and enqueues a follow-up for the rest", %{group: group} do
    drafts = for n <- 1..13, do: group_draft!(group, %{"note" => "#{n}"})
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(DraftNotifier, %{"thread_id" => group.id})

    assert Enum.count(drafts, &Repo.reload!(&1).notified_at) == 12
    assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => group.id})
  end

  test "skips drafts that are already notified", %{group: group} do
    draft = group_draft!(group)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(d in Draft, where: d.id == ^draft.id),
      set: [notified_at: now, updated_at: now]
    )

    Process.delete(:line_client_mock_calls)
    assert :ok = perform_job(DraftNotifier, %{"thread_id" => group.id})
    assert LineMock.calls() == []
  end
end
```

In `test/ganesha/assistant/process_event_worker_test.exs`:
- line 6: replace `GroupDraftNotifier` with `DraftNotifier` in the alias.
- lines 236 and 255: replace each `assert_enqueued(worker: GroupDraftNotifier, args: %{"group_id" => "Cabc"})` with

```elixir
      {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
      assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => group.id})
```

- line 264: `refute_enqueued(worker: DraftNotifier)`.
- add inside `describe "1:1 chats"`, before its closing `end`:

```elixir
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
```

- [ ] **Step 3: Run the tests to make sure they fail**

Run: `mix test test/ganesha/assistant/draft_notifier_test.exs test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL (`module Ganesha.Assistant.DraftNotifier is not available`).

- [ ] **Step 4: Write `DraftNotifier`**

Replace the whole of `lib/ganesha/assistant/draft_notifier.ex` with:

```elixir
defmodule Ganesha.Assistant.DraftNotifier do
  @moduledoc """
  Pushes a thread's pending Drafts that no teacher has been sent yet to every
  teacher's Teacher chat (spec 2026-10-02 §6.6, §7; spec 2026-10-06 §3). The
  Group chat and Student chats propose Drafts their own chat never shows as
  cards.

  A Group chat's run is 3 minutes after its first Draft, and later Drafts
  join it. A Student chat's run is 5 minutes after its latest Draft: each new
  Draft moves the waiting job. Each run pushes one intro text plus one Draft
  carousel (≤ 12 bubbles) in each teacher's own language; the rest wait for
  the next job. The Drafts count as notified once any teacher's push
  succeeds; when every push fails, `notified_at` stays nil so Oban retries
  (max 3).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Ganesha.{Assistant, Repo}
  alias Ganesha.Assistant.{Draft, Thread}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_bubbles 12
  @group_delay 180
  @student_delay 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"thread_id" => thread_id}}) do
    thread = Assistant.get_thread!(thread_id)

    case list_unnotified(thread) do
      [] -> :ok
      drafts -> push_and_mark(drafts, thread)
    end
  end

  @doc """
  Schedules a run when the thread has a pending Draft no teacher has been sent.
  Reads the stored Drafts, not a Turn: a turn that fails after creating a
  Draft still leaves it waiting.
  """
  @spec schedule_if_pending(Thread.t()) :: :ok
  def schedule_if_pending(%Thread{} = thread) do
    if Repo.exists?(unnotified(thread)) do
      {:ok, _} = schedule(thread)
    end

    :ok
  end

  @doc "Enqueues a run with the thread's chat timing (see the moduledoc)."
  @spec schedule(Thread.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(%Thread{source_type: "group", id: id}) do
    %{thread_id: id}
    |> new(schedule_in: @group_delay, unique: [period: @group_delay, keys: [:thread_id]])
    |> Oban.insert()
  end

  def schedule(%Thread{source_type: "user", id: id}) do
    %{thread_id: id}
    |> new(
      schedule_in: @student_delay,
      unique: [period: :infinity, keys: [:thread_id], states: [:available, :scheduled]],
      replace: [scheduled: [:scheduled_at]]
    )
    |> Oban.insert()
  end

  defp unnotified(thread) do
    from d in Draft,
      where: d.thread_id == ^thread.id and d.state == "pending" and is_nil(d.notified_at)
  end

  defp list_unnotified(thread) do
    Repo.all(
      from d in unnotified(thread),
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:student]
    )
  end

  defp push_and_mark(drafts, thread) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)

    results =
      Enum.map(Ganesha.Line.teacher_ids(), fn teacher_id ->
        line_client().push(
          teacher_id,
          messages(thread, shown, length(hidden), teacher_locale(teacher_id))
        )
      end)

    if :ok in results do
      with :ok <- Assistant.mark_drafts_notified(Enum.map(shown, & &1.id)) do
        schedule_remainder(hidden, thread)
      end
    else
      Enum.find(results, {:error, :no_teachers}, &match?({:error, _}, &1))
    end
  end

  defp messages(thread, shown, hidden_count, locale) do
    intro = Labels.t(intro_key(thread), locale)

    text =
      if hidden_count > 0,
        do: intro <> "\n\n" <> Labels.t(:more_drafts, locale, count: hidden_count),
        else: intro

    alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))

    [
      Client.text_message(text),
      Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))
    ]
  end

  defp intro_key(%Thread{source_type: "group"}), do: :group_drafts_push_intro
  defp intro_key(%Thread{source_type: "user"}), do: :student_drafts_push_intro

  # The rest go in the next job (spec §6.6). This job is still executing, so a
  # unique insert could collapse into it; the follow-up skips the unique check.
  defp schedule_remainder([], _thread), do: :ok

  defp schedule_remainder(_hidden, thread) do
    {:ok, _} = %{thread_id: thread.id} |> new(schedule_in: 60, unique: false) |> Oban.insert()
    :ok
  end

  defp teacher_locale(teacher_id) do
    Repo.one(
      from t in Thread,
        where: t.source_type == "teacher" and t.source_id == ^teacher_id,
        select: t.locale
    ) || "zh-TW"
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
```

`lib/ganesha/line/labels.ex`, after `group_drafts_push_intro`:

```elixir
    student_drafts_push_intro:
      {"私訊有人想報名：", "Someone asked to sign up in a private chat:"},
```

`lib/ganesha/assistant.ex` line 247: change "`GroupDraftNotifier` push" to "`DraftNotifier` push".

- [ ] **Step 5: Schedule from the worker and the Conversation**

`lib/ganesha/assistant/process_event_worker.ex`:
- in the alias block (lines 21-29), replace `GroupDraftNotifier,` with `DraftNotifier,` (keep the list alphabetical: after `Conversation,`).
- line 121: `DraftNotifier.schedule_if_pending(thread)`
- line 185: `DraftNotifier.schedule_if_pending(thread)`
- replace the catch-all `rerun_after_edit/2` (lines 189-191) with:

```elixir
  defp rerun_after_edit(thread, _sender_id) do
    thread |> Conversation.run_turn() |> log_failure(thread, "messageEdited")
    if thread.source_type == "user", do: DraftNotifier.schedule_if_pending(thread)
    :ok
  end
```

- delete `maybe_schedule_group_notifier/1` and its comment (lines 193-207).

`lib/ganesha/assistant/conversation.ex`:
- line 17: add `DraftNotifier` to the alias list: `alias Ganesha.Assistant.{Agent, DraftNotifier, Memory, Prompts, Snapshot, Tasks, Thread, Turn}`
- in `handle_message/3`, replace the final `:ok` (line 47) with:

```elixir
    # Spec 2026-10-06 §3: covers a plain message and the turn that runs once a
    # newcomer picks a language.
    if thread.source_type == "user", do: DraftNotifier.schedule_if_pending(thread)
    :ok
```

- [ ] **Step 6: Point the smoke script at the new worker**

`priv/scripts/line_smoke.exs`:
- alias block (lines 22-30): replace `GroupDraftNotifier,` with `DraftNotifier,` (after `Draft,`).
- after line 39 (`secret = ...`), add:

```elixir
smoke_sources = [teacher_id, group_id]
```

- in `cleanup`, add as its first line:

```elixir
  smoke_thread_ids =
    Repo.all(from t in Thread, where: t.source_id in ^smoke_sources, select: t.id)
```

  change both `^[teacher_id, group_id]` (lines 117 and 121) to `^smoke_sources`, and replace the `GroupDraftNotifier` job deletion (lines 138-143) with:

```elixir
  Repo.delete_all(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.DraftNotifier",
      where: fragment("json_extract(?, '$.thread_id')", j.args) in ^smoke_thread_ids
    )
  )
```

- Step 10 (lines 905-918): replace the `notifier_jobs` query, its check and the perform call with:

```elixir
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
```

- [ ] **Step 7: Run the tests and the smoke to make sure they pass**

Run: `mix test test/ganesha/assistant`
Expected: PASS

Run: `mix run priv/scripts/line_smoke.exs`
Expected: `ALL CHECKS PASSED` (Step 6 is skipped in dev).

- [ ] **Step 8: Commit**

```bash
git add lib/ganesha/assistant/draft_notifier.ex lib/ganesha/assistant/group_draft_notifier.ex test/ganesha/assistant/draft_notifier_test.exs test/ganesha/assistant/group_draft_notifier_test.exs lib/ganesha/line/labels.ex lib/ganesha/assistant.ex lib/ganesha/assistant/process_event_worker.ex lib/ganesha/assistant/conversation.ex test/ganesha/assistant/process_event_worker_test.exs priv/scripts/line_smoke.exs
git commit -m "DraftNotifier: push Student chat drafts to teachers after 5 quiet minutes"
```

---

### Task 5: The 「幫他報名」 button

**Files:**
- Modify: `lib/ganesha/line/cards.ex:12-41`
- Modify: `lib/ganesha/line/labels.ex` (button label)
- Modify: `lib/ganesha/assistant/tasks/signup_request.ex` (add `teacher_message/3`)
- Modify: `lib/ganesha/assistant/conversation.ex:17,95-129` and add private helpers
- Modify: `lib/ganesha/assistant/prompts.ex:106-109` (teacher rule 11)
- Test: `test/ganesha/line/cards_test.exs`
- Test: `test/ganesha/assistant/conversation_test.exs` (`describe "handle_postback/4"`)

**Interfaces:**
- Consumes: `SignupRequest` (Task 2); `Conversation.handle_message/3` (Task 3/4).
- Produces: postback `action=enroll_from_request&draft_id=N`; `SignupRequest.teacher_message(id :: pos_integer(), parsed :: map(), locale :: String.t()) :: String.t()`; label `:enroll_from_request`.

- [ ] **Step 1: Write the failing tests**

`test/ganesha/line/cards_test.exs`, inside `describe "draft_bubble/2"`:

```elixir
    test "a sign-up request card leads with 幫他報名, then Confirm and Discard" do
      {:ok, thread} = Assistant.get_or_create_thread("user", "Unewcomer")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "signup_request",
          parsed: %{"note" => "想報名", "new" => true, "line_user_id" => "Unewcomer"}
        })

      bubble = Cards.draft_bubble(draft, "zh-TW")

      assert Enum.map(bubble.footer.contents, & &1.action.data) == [
               "action=enroll_from_request&draft_id=#{draft.id}",
               "action=confirm&draft_id=#{draft.id}",
               "action=discard&draft_id=#{draft.id}"
             ]
    end
```

`test/ganesha/assistant/conversation_test.exs`: add `SignupRequest` to the task alias (`alias Ganesha.Assistant.Tasks.{BookOneOff, RecordPayment, SignupRequest}`), add this helper next to `payment_draft/3`:

```elixir
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
```

and add inside `describe "handle_postback/4"`:

```elixir
    test "幫他報名 settles a known student's request and runs a turn in her chat", %{
      thread: thread
    } do
      {:ok, amy} = People.create_student(%{display_name: "Amy", line_user_id: "Uamy"})
      draft = signup_draft("Uamy")
      model([], "好，要幫 Amy 報名哪一堂？")

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-e", @teacher)

      assert Repo.reload!(draft).state == "applied"

      assert [_confirmed_line, request, reply] =
               thread |> Assistant.list_messages() |> Enum.take(-3)

      assert request.role == "user"
      assert request.content =~ "##{draft.id}"
      assert request.content =~ "Amy"
      assert request.content =~ "##{amy.id}"
      assert reply.content == "好，要幫 Amy 報名哪一堂？"

      assert [{:loading, _}, {:reply, {"rt-e", [%{text: "好，要幫 Amy 報名哪一堂？"}]}}] =
               LineMock.calls()
    end

    test "a newcomer's request hands the model their LINE ID to add them first", %{
      thread: thread
    } do
      Process.put(:line_client_mock_profile, {:ok, %{"displayName" => "小美"}})
      draft = signup_draft("Unewcomer")
      model([], "先新增小美，確認後跟我說「繼續」。")

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-e", @teacher)

      request = thread |> Assistant.list_messages() |> Enum.find(&(&1.role == "user"))
      assert request.content =~ "Unewcomer"
      assert request.content =~ "小美"
    end

    test "a request already handled says so and runs no turn", %{thread: thread} do
      draft = signup_draft("Unewcomer")
      {:ok, _} = Assistant.confirm_draft(draft, "line:teacher")
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

    test "only a teacher may tap 幫他報名" do
      draft = signup_draft("Unewcomer")

      :ok = Conversation.handle_postback(enroll_tap(draft.id), "rt-x", "Ustranger")

      assert Repo.reload!(draft).state == "pending"
      unknown = Labels.t(:unknown_action, "zh-TW")
      assert [{:reply, {"rt-x", [%{text: ^unknown}]}}] = LineMock.calls()
    end
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/line/cards_test.exs test/ganesha/assistant/conversation_test.exs`
Expected: FAIL. The card has two buttons, and `enroll_from_request` falls through to `:unknown_action`.

- [ ] **Step 3: Add the button**

`lib/ganesha/line/labels.ex`, after `discard:`:

```elixir
    enroll_from_request: {"幫他報名", "Sign them up"},
```

`lib/ganesha/line/cards.ex`, replace the moduledoc first line and `draft_bubble/2` (lines 2-41) with:

```elixir
  @moduledoc """
  The Draft card (chat-first replies spec §2): one sentence and 確認 / 捨棄,
  plus 「幫他報名」 first on a sign-up request (spec 2026-10-06 §5).
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Labels

  @max_bubbles 12

  @doc "A Draft as one sentence with its buttons (chat-first replies spec §2)."
  @spec draft_bubble(Draft.t(), String.t()) :: map()
  def draft_bubble(%Draft{} = draft, locale) do
    buttons =
      shortcut_buttons(draft, locale) ++
        [
          button("primary", %{
            type: "postback",
            label: Labels.t(:confirm, locale),
            data: "action=confirm&draft_id=#{draft.id}"
          }),
          button("secondary", %{
            type: "postback",
            label: Labels.t(:discard, locale),
            data: "action=discard&draft_id=#{draft.id}"
          })
        ]

    %{
      type: "bubble",
      size: "kilo",
      body: %{
        type: "box",
        layout: "vertical",
        contents: [%{type: "text", text: Assistant.draft_summary(draft, locale), wrap: true}]
      },
      footer: %{
        type: "box",
        # Three buttons do not fit side by side in a kilo bubble.
        layout: if(length(buttons) > 2, do: "vertical", else: "horizontal"),
        spacing: "sm",
        contents: buttons
      }
    }
  end

  defp shortcut_buttons(%Draft{kind: "signup_request", id: id}, locale) do
    [
      button("primary", %{
        type: "postback",
        label: Labels.t(:enroll_from_request, locale),
        data: "action=enroll_from_request&draft_id=#{id}"
      })
    ]
  end

  defp shortcut_buttons(_draft, _locale), do: []
```

(the `@moduledoc`, aliases and `@max_bubbles` replace the existing ones at lines 2-10; `history_line/2`, `draft_carousel/2` and `button/2` stay as they are.)

- [ ] **Step 4: Add the request message to the task**

`lib/ganesha/assistant/tasks/signup_request.ex`, after `summary/2`:

```elixir
  @doc """
  What 「幫他報名」 adds to the Teacher chat as her message (spec 2026-10-06
  §5), so the model proposes enroll, or add_student first for a newcomer.
  """
  @spec teacher_message(pos_integer(), map(), String.t()) :: String.t()
  def teacher_message(id, %{"new" => false} = parsed, "en"),
    do:
      "[Sign-up request ##{id}] Sign up #{parsed["student_name"]} " <>
        "(student ##{parsed["student_id"]}): #{parsed["note"]}"

  def teacher_message(id, %{"new" => false} = parsed, _locale),
    do:
      "[報名申請 ##{id}] 幫 #{parsed["student_name"]}（學生 ##{parsed["student_id"]}）" <>
        "報名：#{parsed["note"]}"

  def teacher_message(id, parsed, "en"),
    do:
      "[Sign-up request ##{id}] #{newcomer(parsed, "en")} (LINE ID #{parsed["line_user_id"]}, " <>
        "not a student yet) wants to sign up: #{parsed["note"]}. Add the student first, " <>
        "linked to this LINE ID; sign them up after I confirm."

  def teacher_message(id, parsed, locale),
    do:
      "[報名申請 ##{id}] #{newcomer(parsed, locale)}（LINE ID #{parsed["line_user_id"]}，" <>
        "還不是學生）想報名：#{parsed["note"]}。請先新增這位學生並連結這個 LINE ID，" <>
        "我確認後再幫他報名。"

  defp newcomer(%{"line_name" => name}, "en") when is_binary(name), do: "Newcomer #{name}"
  defp newcomer(_parsed, "en"), do: "Newcomer"
  defp newcomer(%{"line_name" => name}, _locale) when is_binary(name), do: "新朋友 #{name}"
  defp newcomer(_parsed, _locale), do: "新朋友"
```

- [ ] **Step 5: Handle the postback**

`lib/ganesha/assistant/conversation.ex`:
- line 17: add `Draft` to the alias list: `alias Ganesha.Assistant.{Agent, Draft, DraftNotifier, Memory, Prompts, Snapshot, Tasks, Thread, Turn}`
- add `alias Ganesha.Assistant.Tasks.SignupRequest` on the next line.
- after the confirm/discard clause (ends line 102), add:

```elixir
  # Spec 2026-10-06 §5: 「幫他報名」 settles a sign-up request and hands it to
  # this teacher's own chat as a normal turn.
  def handle_postback(%{"action" => "enroll_from_request"} = params, reply_token, source_id) do
    if Ganesha.Line.teacher?(source_id),
      do: enroll_from_request(parse_id(params["draft_id"]), reply_token, source_id),
      else: unknown_action(reply_token, source_id)
  end
```

- replace `settle_postback/4` (lines 117-129) with:

```elixir
  defp settle_postback(action, params, reply_token, source_id) do
    thread = thread_for(source_id)
    outcome = settle(action, parse_id(params["draft_id"]), locale(thread))
    deliver_outcome(thread, reply_token, source_id, outcome)
  end

  defp enroll_from_request(id, reply_token, source_id) do
    thread = thread_for(source_id)
    locale = locale(thread)

    with %Draft{} = draft <- signup_request(id),
         {:applied, applied} = result <- outcome("confirm", draft) do
      {_text, history_line} = describe_outcome(result, locale)
      {:ok, _} = Assistant.append_message(thread, "assistant", history_line, nil)

      {:ok, _} =
        Assistant.append_message(
          thread,
          "user",
          SignupRequest.teacher_message(applied.id, applied.parsed, locale),
          nil
        )

      handle_message(thread, reply_token, source_id)
    else
      nil ->
        deliver_outcome(thread, reply_token, source_id, {Labels.t(:not_found, locale), nil})

      other ->
        deliver_outcome(thread, reply_token, source_id, describe_outcome(other, locale))
    end
  end

  defp signup_request(nil), do: nil

  defp signup_request(id) do
    case Assistant.get_draft(id) do
      %Draft{kind: "signup_request"} = draft -> draft
      _other -> nil
    end
  end

  defp deliver_outcome(thread, reply_token, source_id, {text, history_line}) do
    deliver(reply_token, source_id, [Client.text_message(text)], nil)

    if history_line do
      {:ok, _} = Assistant.append_message(thread, "assistant", history_line, nil)
    end

    :ok
  end
```

- [ ] **Step 6: Teach the teacher prompt**

`lib/ganesha/assistant/prompts.ex`, in `teacher_rules/0`, after rule 10 (before the closing `"""`):

```elixir
    11. Sign-up requests: a message starting with "[報名申請 #N]" or "[Sign-up request #N]" \
    comes from the button she tapped on a student's sign-up request. Propose enroll with \
    ids from the snapshot; if the class, month or package is unclear, call ask_teacher. \
    If the person is not a student yet, propose only add_student with the given LINE user \
    id, and end your reply asking her to say 「繼續」 after confirming so you can propose \
    enroll.
```

- [ ] **Step 7: Run the tests to make sure they pass**

Run: `mix test test/ganesha/line test/ganesha/assistant`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/ganesha/line/cards.ex lib/ganesha/line/labels.ex lib/ganesha/assistant/tasks/signup_request.ex lib/ganesha/assistant/conversation.ex lib/ganesha/assistant/prompts.ex test/ganesha/line/cards_test.exs test/ganesha/assistant/conversation_test.exs
git commit -m "Sign-up request cards: 幫他報名 starts enroll in the teacher's chat"
```

---

### Task 6: Smoke Step 12 and full verification

**Files:**
- Modify: `priv/scripts/line_smoke.exs` (constants, `smoke_sources`, new Step 12 before teardown)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Add the newcomer to the smoke constants**

After `blocked_sender_id = ...` (line 38):

```elixir
newcomer_id = "Usmokenewcomer00000000000000000"
```

and change `smoke_sources` (added in Task 4) to:

```elixir
smoke_sources = [teacher_id, group_id, newcomer_id]
```

- [ ] **Step 2: Add Step 12**

Insert before `# ---------------------------------------------------------------- teardown`:

```elixir
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
```

- [ ] **Step 3: Run the smoke**

Run: `mix run priv/scripts/line_smoke.exs`
Expected: `ALL CHECKS PASSED`, including Step 12's six checks.

- [ ] **Step 4: Run precommit**

Run: `mix precommit`
Expected: compiles without warnings, formatted, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add priv/scripts/line_smoke.exs
git commit -m "Smoke: a newcomer's sign-up request reaches the teacher and 幫他報名"
```

- [ ] **Step 6: Manual check on the dev LINE channel**

Restart the dev server with `.env.dev` sourced (teacher list: Vicky only). From Mickey's 1:1 chat, send 「想報名週一晚上的課」. About 5 minutes later Vicky's chat gets 「私訊有人想報名：」 and a card with 幫他報名 / 確認 / 捨棄. Tapping 幫他報名 gives an `add_student` card for "Mickey".
