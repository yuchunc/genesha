# LINE Teacher Assistant — Slice 5 (Group delivery) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push Group chat Drafts to the Teacher chat after a short delay, list every pending Draft on the web dashboard, and let the Teacher chat show all pending Drafts as a carousel via the `pending_drafts` lookup task.

**Architecture:** When `ProcessEventWorker` handles a group message whose agent turn returns non-empty `Turn.draft_ids`, it inserts `Ganesha.Assistant.GroupDraftNotifier` with `schedule_in: 180` and Oban unique `period: 180, keys: [:group_id]`. The worker pushes one text line plus a Draft carousel (≤ 12) to `teacher_line_user_id`, then sets `notified_at` on those Drafts. The Teacher-only lookup `pending_drafts` returns `draft_ids` from `Assistant.list_pending_drafts/0`; the agent merges them into `Turn.draft_ids` so `Ganesha.Line.Reply` packs them like Drafts created in the same turn. The dashboard loads `list_pending_drafts/0` on mount and renders title (`describe_draft/2`), time, and a student link.

**Tech Stack:** Elixir 1.20, Phoenix 1.8.13, Ecto + SQLite, Oban 2.24 (`Oban.Engines.Lite`), existing `Ganesha.Line.Client` / `Client.Mock`, `Provider.Mock` for tests.

**Spec:** `docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md` — slice 5 of §9 (§6.6 Group chat Drafts, §3.1 task #22, §7 notifier errors, §8 testing). Read `GLOSSARY.md` and ADRs 0001–0003. Builds on slices 1–4 on branch `line-teacher-assistant`.

## Global Constraints

Carry forward slice 1 **Global Constraints** (`docs/superpowers/plans/2026-10-02-line-assistant-slice-1-foundation.md`) in full. Additionally for slice 5:

- **§6.6:** `GroupDraftNotifier` uses `schedule_in: 180`, `unique: [period: 180, keys: [:group_id]]`; one push = text + Draft carousel ≤ 12; set `notified_at` only after a successful push; remainder wait for the next job.
- **§7:** Notifier push failure → `notified_at` stays nil; Oban retries (`max_attempts: 3`).
- **§3.1 #22:** `pending_drafts` is `:lookup`, Teacher chat only; domain read is `Assistant.list_pending_drafts/0`.
- **Reply (§6.2):** Still ≤ 5 messages, ≤ 12 carousel bubbles; `pending_drafts` Drafts use the same carousel path as `:change` Drafts on the Turn.
- **Confirm (§6.3):** Only `teacher_line_user_id` may confirm; Group-origin Drafts are unchanged.
- **Tests:** Inline fixtures; no `Process.sleep`; assert behaviour not user-facing prose; membership asserts for `@teacher` task list (do not assert the full sorted teacher list after slices 2–4 land).
- **AGENTS.md:** Dashboard uses `<Layouts.app flash={@flash} current_scope={@current_scope}>`; unique DOM ids; LiveView tests use `element/2` and `has_element/2`.
- **Never** `alias Ganesha.Assistant.Task`. **Never** call bare `apply/2` inside a task module.

## File Structure

| File | Responsibility |
|---|---|
| `lib/ganesha/assistant/tasks/pending_drafts.ex` | Lookup task #22. |
| `lib/ganesha/assistant/group_draft_notifier.ex` | Oban worker (§6.6). |
| `lib/ganesha/assistant.ex` | `mark_drafts_notified/1`. |
| `lib/ganesha/assistant/task.ex` | Optional `draft_ids` on `answer/2`. |
| `lib/ganesha/assistant/agent.ex` | Merge lookup `draft_ids` into Turn. |
| `lib/ganesha/assistant/tasks.ex` | Register `PendingDrafts` on `@teacher`. |
| `lib/ganesha/assistant/turn.ex` | Doc: listed Drafts. |
| `lib/ganesha/assistant/process_event_worker.ex` | Schedule notifier when group turn creates Drafts. |
| `lib/ganesha/line/labels.ex` | Push intro + dashboard copy. |
| `lib/ganesha_web/live/dashboard_live.ex` | Pending Drafts section. |
| `test/ganesha/assistant/tasks/pending_drafts_test.exs` | Task tests. |
| `test/ganesha/assistant/group_draft_notifier_test.exs` | Notifier + Oban unique. |
| `test/ganesha/assistant/agent_test.exs` | Lookup `draft_ids` on Turn. |
| `test/ganesha/assistant/process_event_worker_test.exs` | Enqueue / no-enqueue. |
| `test/ganesha/assistant/conversation_test.exs` | Teacher tools membership includes `pending_drafts`. |
| `test/ganesha/assistant/tasks_test.exs` | Registry + fetch (anchor: add `PendingDrafts` to membership list). |
| `test/ganesha_web/live/dashboard_live_test.exs` | `#pending-draft-*` elements. |
| `test/ganesha/line/labels_test.exs` | New label keys. |
| `priv/scripts/line_smoke.exs` | **Step 10** before `# ---------------------------------------------------------------- teardown`. |

**Smoke step numbering:** Slice 2 owns Step 7, slice 3 Step 8, slice 4 Step 9; this slice is **Step 10** at the same anchor.

---

### Task 1: Lookup answers may name Drafts on the Turn

**Files:**
- Modify: `lib/ganesha/assistant/task.ex`, `lib/ganesha/assistant/agent.ex`, `lib/ganesha/assistant/turn.ex`
- Test: `test/ganesha/assistant/agent_test.exs`

**Interfaces:**
- Consumes: existing `Turn.draft_ids`, `run_task(:lookup, ...)`.
- Produces: `answer/2` may return `draft_ids: [integer()]`; agent appends unseen ids once (dedupes against `turn.draft_ids`).

In `lib/ganesha/assistant/task.ex`, add to the moduledoc after the `describe/2` bullet:

- A `:lookup` answer may name pending Drafts in `draft_ids`; the agent adds them to the Turn, so they are shown as the Draft carousel (`pending_drafts`).

Extend the `answer/2` typespec map with `optional(:draft_ids) => [integer()]`.

In `lib/ganesha/assistant/agent.ex` moduledoc, extend the `:lookup` bullet to mention `draft_ids`.

Replace `run_task(:lookup, ...)` success branch with:

```elixir
  defp run_task(:lookup, task, input, %Turn{} = turn, ctx) do
    case task.answer(input, ctx) do
      {:ok, %{data: data} = answer} ->
        cards =
          if input["show_card"] == true and Map.has_key?(answer, :card),
            do: turn.cards ++ [answer.card],
            else: turn.cards

        listed = Map.get(answer, :draft_ids, []) -- turn.draft_ids

        {data, %Turn{turn | cards: cards, draft_ids: turn.draft_ids ++ listed}}

      {:error, text} ->
        {text, turn}
    end
  end
```


- [ ] **Step 1: Write the failing test**

Add to `test/ganesha/assistant/agent_test.exs` (alias `PendingDrafts`):

```elixir
  test "a lookup's draft_ids join the Turn", %{thread: thread, history: history} do
    {:ok, draft} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

    script([[call("t1", "pending_drafts", %{})]])

    assert {:ok, %Turn{draft_ids: [id]}} =
             Agent.run(thread, [PendingDrafts], "system", history)

    assert id == draft.id
  end
```

- [ ] **Step 2: Run test** — `mix test test/ganesha/assistant/agent_test.exs:193` — FAIL until Task 2 exists.

- [ ] **Step 3: Apply task.ex / agent.ex / turn.ex changes** (see agent patch above).

- [ ] **Step 4: Re-run agent tests** — PASS after Task 2.

- [ ] **Step 5: Commit** — `git add lib/ganesha/assistant/task.ex lib/ganesha/assistant/agent.ex lib/ganesha/assistant/turn.ex test/ganesha/assistant/agent_test.exs && git commit -m "Agent: lookup draft_ids join the Turn"`

---

### Task 2: `pending_drafts` lookup task and registry

**Files:**
- Create: `lib/ganesha/assistant/tasks/pending_drafts.ex`
- Modify: `lib/ganesha/assistant/tasks.ex` (add `PendingDrafts` to alias and **append** to `@teacher` — do not replace the list)
- Test: `test/ganesha/assistant/tasks/pending_drafts_test.exs`, `test/ganesha/assistant/tasks_test.exs`

**Interfaces:**
- Consumes: `Assistant.list_pending_drafts/0`, `Ganesha.Line.Cards.history_line/2`.
- Produces: `Ganesha.Assistant.Tasks.PendingDrafts`, `name/0 == "pending_drafts"`, `kind/0 == :lookup`.

- [ ] **Step 1: Write failing tests** — `test/ganesha/assistant/tasks/pending_drafts_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.PendingDraftsTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.Tasks.PendingDrafts
  alias Ganesha.Line.Cards

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, group} = Assistant.get_or_create_thread("group", "Cgroup")

    %{
      teacher: teacher,
      group: group,
      ctx: %{thread: teacher, locale: "zh-TW", today: Clock.today()}
    }
  end

  defp makeup_draft(thread, note) do
    {:ok, draft} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => note}})

    draft
  end

  test "names every pending Draft from every chat, oldest first", c do
    from_teacher = makeup_draft(c.teacher, "8/17")
    from_group = makeup_draft(c.group, "8/24")
    {:ok, _} = c.teacher |> makeup_draft("8/31") |> Assistant.discard_draft()

    assert {:ok, %{data: data, draft_ids: ids}} = PendingDrafts.answer(%{}, c.ctx)
    assert ids == [from_teacher.id, from_group.id]

    for draft <- [from_teacher, from_group] do
      assert data =~ Cards.history_line({:draft, draft}, "zh-TW")
    end
  end

  test "with nothing pending, names no Drafts", c do
    assert {:ok, %{draft_ids: []}} = PendingDrafts.answer(%{}, c.ctx)
  end
end
```


In `test/ganesha/assistant/tasks_test.exs`, add `PendingDrafts` to the alias list and to the **membership** `for task <- [...]` loop (same style as slice 2); add `assert {:ok, PendingDrafts} = Tasks.fetch("pending_drafts")`. Do **not** restore an exact sorted `@teacher` list.

- [ ] **Step 2: Run** — `mix test test/ganesha/assistant/tasks/pending_drafts_test.exs` — FAIL.

- [ ] **Step 3: Implement task module**

```elixir
defmodule Ganesha.Assistant.Tasks.PendingDrafts do
  @moduledoc """
  Lookup task `pending_drafts` (spec §3.1 #22): every pending Draft, from any
  chat, shown to the teacher as the turn's Draft carousel. Its answer carries
  the Drafts' ids as `draft_ids`, which the agent adds to the Turn, so
  `Ganesha.Line.Reply` packs them like the Drafts a turn creates (≤ 12 cards,
  the rest counted in the text). Teacher chat only: a Draft card's buttons
  only work for the teacher anyway (spec §6.3).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Assistant
  alias Ganesha.Line.Cards

  @impl true
  def name, do: "pending_drafts"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      List every Draft still waiting for the teacher to confirm or discard, from this \
      chat and from the group. Their Draft cards are always shown under your reply, \
      oldest first; show_card is not needed. Use it when she asks what is waiting \
      (待確認草稿) or needs a pending Draft's id.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, ctx) do
    drafts = Assistant.list_pending_drafts()
    {:ok, %{data: data(drafts, ctx.locale), draft_ids: Enum.map(drafts, & &1.id)}}
  end

  defp data([], _locale), do: "No Drafts are pending."

  defp data(drafts, locale) do
    lines = Enum.map(drafts, &Cards.history_line({:draft, &1}, locale))
    Enum.join(["#{length(drafts)} pending, shown to the teacher as cards:" | lines], "\n")
  end
end
```


- [ ] **Step 4: Register** — in `tasks.ex`:

```elixir
  alias Ganesha.Assistant.Tasks.{
    AskTeacher,
    BookOneOff,
    MakeupRequest,
    PendingDrafts,
    RecordPayment,
    SetLanguage
  }

  @teacher [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage, PendingDrafts]
```

- [ ] **Step 5: Run** — `mix test test/ganesha/assistant/tasks/pending_drafts_test.exs test/ganesha/assistant/tasks_test.exs test/ganesha/assistant/agent_test.exs` — PASS.

- [ ] **Step 6: Commit** — `feat: add pending_drafts lookup for Teacher chat`

---

### Task 3: `GroupDraftNotifier` and `mark_drafts_notified/1`

**Files:**
- Create: `lib/ganesha/assistant/group_draft_notifier.ex`
- Modify: `lib/ganesha/assistant.ex`, `lib/ganesha/line/labels.ex`, `test/ganesha/line/labels_test.exs`
- Test: `test/ganesha/assistant/group_draft_notifier_test.exs`

- [ ] **Step 1: Write failing tests** — copy `test/ganesha/assistant/group_draft_notifier_test.exs` from this plan's verified tree (push success, push failure leaves `notified_at` nil, `schedule/1` unique, skips notified).

- [ ] **Step 2: Add labels** (`group_drafts_push_intro`, `pending_drafts_section`, `pending_drafts_empty`, `pending_drafts_student_link`) and extend `@keys` in `labels_test.exs`.

- [ ] **Step 3: Add `mark_drafts_notified/1`** to `Assistant` after `list_pending_drafts/0`:

```elixir
  @doc """
  Sets `notified_at` on the listed pending Drafts (spec §6.6). Used after a
  successful `GroupDraftNotifier` push. Returns `{:error, :not_all_marked}`
  when any id is missing or no longer pending, so a partial push can retry.
  """
  def mark_drafts_notified(ids) when is_list(ids) do
    now = now()

    {count, _} =
      from(d in Draft, where: d.id in ^ids and d.state == "pending")
      |> Repo.update_all(set: [notified_at: now, updated_at: now])

    if count == length(ids), do: :ok, else: {:error, :not_all_marked}
  end
```

- [ ] **Step 4: Implement worker**

```elixir
defmodule Ganesha.Assistant.GroupDraftNotifier do
  @moduledoc """
  Pushes pending Group chat Drafts to the Teacher chat (spec §6.6, §7).

  Inserted with `schedule_in: 180` and `unique: [period: 180, keys: [:group_id]]`
  when a group turn creates Drafts. Each run pushes every still-pending,
  still-unnotified Draft from that group as one text message plus one Draft
  carousel (≤ 12 bubbles); the rest wait for the next job. A push failure
  leaves `notified_at` nil so Oban retries (max 3).
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 180, keys: [:group_id], states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Ganesha.{Assistant, Repo}
  alias Ganesha.Assistant.{Draft, Thread}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_bubbles 12

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"group_id" => group_id}}) do
    drafts = list_unnotified_group_drafts(group_id)

    if drafts == [] do
      :ok
    else
      push_and_mark(drafts, group_id)
    end
  end

  @doc """
  Enqueues a notifier run in three minutes. Repeated group Drafts inside the
  unique window collapse to one job (spec §6.6).
  """
  @spec schedule(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(group_id) when is_binary(group_id) do
    %{group_id: group_id}
    |> new(schedule_in: 180, unique: [period: 180, keys: [:group_id]])
    |> Oban.insert()
  end

  defp list_unnotified_group_drafts(group_id) do
    Repo.all(
      from d in Draft,
        join: t in Thread,
        on: d.thread_id == t.id,
        where: t.source_type == "group" and t.source_id == ^group_id,
        where: d.state == "pending" and is_nil(d.notified_at),
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:student]
    )
  end

  defp push_and_mark(drafts, _group_id) do
    locale = teacher_locale()
    {shown, hidden} = Enum.split(drafts, @max_bubbles)
    hidden_count = length(hidden)

    text =
      if hidden_count > 0 do
        Labels.t(:group_drafts_push_intro, locale) <>
          "\n\n" <>
          Labels.t(:more_drafts, locale, count: hidden_count)
      else
        Labels.t(:group_drafts_push_intro, locale)
      end

    alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))

    messages = [
      Client.text_message(text),
      Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))
    ]

    teacher_id = teacher_line_user_id()

    with :ok <- line_client().push(teacher_id, messages),
         :ok <- Assistant.mark_drafts_notified(Enum.map(shown, & &1.id)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp teacher_locale do
    teacher_id = teacher_line_user_id()

    case Repo.one(
           from t in Thread,
             where: t.source_type == "teacher" and t.source_id == ^teacher_id,
             select: t.locale
         ) do
      nil -> "zh-TW"
      locale -> locale || "zh-TW"
    end
  end

  defp teacher_line_user_id do
    Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
```


- [ ] **Step 5: Run** — `mix test test/ganesha/assistant/group_draft_notifier_test.exs` — PASS.

- [ ] **Step 6: Commit**

---

### Task 4: Schedule notifier from the group path

**Files:**
- Modify: `lib/ganesha/assistant/process_event_worker.ex`
- Test: `test/ganesha/assistant/process_event_worker_test.exs`

- [ ] **Step 1: Write failing tests** — after "can produce a pending Draft", `assert_enqueued(worker: GroupDraftNotifier, args: %{"group_id" => "Cabc"})`; new test `refute_enqueued` when agent returns no Drafts.

- [ ] **Step 2: Implement** — alias `GroupDraftNotifier` and `Turn`; after `run_group_agent(thread)`, `GroupDraftNotifier.schedule(group_id)` when `{:ok, %Turn{draft_ids: ids}}` and `ids != []`.

- [ ] **Step 3: Run** — `mix test test/ganesha/assistant/process_event_worker_test.exs` — PASS.

- [ ] **Step 4: Commit**

---

### Task 5: Dashboard pending Drafts section

**Files:**
- Modify: `lib/ganesha_web/live/dashboard_live.ex`
- Test: `test/ganesha_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Write failing test** — `has_element?(view, "#pending-drafts-section")`, `#pending-draft-<id>`, `#pending-draft-student-<id>` when a pending Draft with `student_id` exists.

- [ ] **Step 2: Implement** — `assign_pending_drafts/1` on mount; private `pending_drafts/1` component with `<.section id="pending-drafts-section">`, rows `id={"pending-draft-#{draft.id}"}`, student link `navigate={~p"/students/#{draft.student.id}"}` with `id={"pending-draft-student-#{draft.id}"}`; use `Labels.t/2` for section title / empty / link prefix; `Calendar.strftime(draft.inserted_at, "%Y-%m-%d %H:%M")` for created time.

- [ ] **Step 3: Run** — `mix test test/ganesha_web/live/dashboard_live_test.exs` — PASS.

- [ ] **Step 4: Commit**

---

### Task 6: Teacher chat tool list and optional `pending_drafts` turn test

**Files:**
- Modify: `test/ganesha/assistant/conversation_test.exs`

- [ ] **Step 1: Fix membership assert** in "gives the model the snapshot…" — require `pending_drafts` in tool names (loop over expected names, not exact list).

- [ ] **Step 2 (optional but recommended):** Add test that stubs `pending_drafts` tool call and asserts reply includes a flex carousel (same pattern as `record_payment` test; assert postback buttons on bubble, not button label strings).

- [ ] **Step 3: Run** — `mix test test/ganesha/assistant/conversation_test.exs` — PASS.

- [ ] **Step 4: Commit**

---

### Task 7: Offline smoke — group → notifier → confirm (Step 10)

**Files:**
- Modify: `priv/scripts/line_smoke.exs` (insert **before** `# ---------------------------------------------------------------- teardown`)

- [ ] **Step 1: Add Step 10** — group `record_payment` turn → assert notifier job enqueued → `GroupDraftNotifier.perform/1` inline → assert `push` to teacher and `notified_at` set → teacher postback confirm → `state == "applied"`. Reuse `student`, `purchase`, `teacher_id`, `group_id` from earlier steps; alias `GroupDraftNotifier`.

- [ ] **Step 2: Run** — `mix run priv/scripts/line_smoke.exs` — ALL CHECKS PASSED.

- [ ] **Step 3: Commit**

---

### Task 8: `mix precommit`

- [ ] **Step 1:** `mix precommit` — 0 failures.

- [ ] **Step 2:** Commit any formatter output.

---

## Decisions this plan makes where the spec is silent

- **Lookup `draft_ids`:** Rather than a special-case in `Reply` or `Conversation`, `pending_drafts` returns ids in `answer/2` and the agent merges them into `Turn.draft_ids` (same packing as Drafts created in-turn). Dedupes ids already on the Turn.
- **Notifier locale:** Push text uses the Teacher chat thread's `locale` (default `zh-TW`).
- **Dashboard locale:** Fixed `zh-TW` for labels (dashboard UI is Chinese-first like other variants).
- **When to schedule:** Only when `Agent.run` returns `{:ok, %Turn{draft_ids: non_empty}}` for the group turn — not on agent failure (no duplicate notifier for empty turns).
- **`mark_drafts_notified/1`:** All ids must still be `pending` or the function returns `{:error, :not_all_marked}` so a failed partial update can retry.
- **Oban `unique` states:** `[:available, :scheduled, :executing]` so bursts of group Drafts inside 180s coalesce (verified in tests).

## Verification record (plan author)

Applied this plan's code in a throwaway copy of branch HEAD at `/tmp/plan-slice-5` (detached worktree). Results:

- `mix compile --warnings-as-errors` — OK
- `mix test` — **516 tests, 0 failures**
- `mix run priv/scripts/line_smoke.exs` — **ALL CHECKS PASSED** (including Step 10)
- `mix precommit` — OK

---

**Plan complete and saved to `docs/superpowers/plans/2026-10-02-line-assistant-slice-5-group-delivery.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks.

**2. Inline Execution** — `executing-plans` with checkpoints.

**Which approach?**
