# LINE Teacher Assistant — Slice 3 (Schedule) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Ganesha.Scheduling` for shared schedule writes, move the web month and schedule flows onto it, and register the five Teacher-only schedule change tasks (spec §3.1 #7–11) with confirm-time re-checks and Draft cards.

**Architecture:** `Ganesha.Scheduling.cancel_session/2` and `add_weekly_class/2` wrap the same `Studio` + `Roster` steps `MonthLive` and `ScheduleLive` already perform, in one transaction. Each `Ganesha.Assistant.Tasks.*` module follows slice 1 patterns: `propose/2` captures ids, before-values and counts; `apply/2` calls domain functions only after re-checking; `describe/2` reads `parsed` only. `Studio.count_new_sessions_for_month/1` and `Roster.cancellation_credit_count/1` back the counts shown on Draft cards at propose time.

**Tech Stack:** Elixir 1.20, Phoenix 1.8.13, Ecto + SQLite, Oban (unchanged). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md` — slice 3 of §9. Also read `GLOSSARY.md`, `docs/adr/0001-every-line-write-is-a-draft.md`, `0002-line-tools-are-use-cases.md`, and slice 2's `Format.session_day/2` + `Format.month_title/2` (do not redefine).

## Global Constraints

Spec §2 rules and slice 1 `Global Constraints` apply verbatim (Draft-only writes, confirm re-check, Teacher gets every task, Group gets three tasks only, cards from stored values, etc.).

Slice 3 additions:

- `Ganesha.Assistant.Format.money/1` is the only money formatter; use `Format.session_day/2` and `Format.month_title/2` for dates on Draft cards.
- `Ganesha.Clock` owns Taipei calendar logic; month boundaries use `Clock.end_of_month/1` where `Studio` already does.
- Never `alias Ganesha.Assistant.Task`; never call bare `apply(...)` inside a task module — always `@impl true def apply(...)`.
- Tests assert behaviour, not prose wording; derive display strings from `Fmt` / `Format` when needed. Inline fixtures only; no `Process.sleep`.
- Register schedule tasks on `@teacher` only; add membership tests (slice 2 rewrites the exact teacher list assert — follow that pattern).
- Shared-file edits are **additions** anchored to stable lines (extend `@teacher`, add functions to `Studio`/`Roster`, do not replace whole files).
- `priv/scripts/line_smoke.exs`: if you extend it, add **Step 8** immediately before the `# ---- teardown` comment (slice 2 owns Step 7). This slice adds `priv/scripts/line_real_schedule.exs` for the real Sonnet run (do not edit `line_real_turn.exs`).

## File map

| Action | Path |
|--------|------|
| Create | `lib/ganesha/scheduling.ex`, `test/ganesha/scheduling_test.exs` |
| Create | `lib/ganesha/assistant/tasks/{cancel_session,set_session_style,add_session,add_slot,copy_month}.ex` + matching `test/ganesha/assistant/tasks/*_test.exs` |
| Create | `priv/scripts/line_real_schedule.exs` |
| Modify | `lib/ganesha/roster.ex` (`cancellation_credit_count/1`) |
| Modify | `lib/ganesha/studio.ex` (`count_new_sessions_for_month/1`) |
| Modify | `lib/ganesha/assistant/tasks.ex` (Teacher registry) |
| Modify | `lib/ganesha_web/live/month_live.ex`, `schedule_live.ex` |
| Modify | `test/ganesha/assistant/tasks_test.exs`, `test/ganesha/assistant/conversation_test.exs` (tool list membership) |

Task order: Scheduling + LiveViews (1) → Roster/Studio helpers (2) → tasks 3–7 → registry + conversation test (8) → real schedule script + precommit (9).

---

### Task 1: `Ganesha.Scheduling` and LiveView wiring

**Create:** `lib/ganesha/scheduling.ex`

```elixir
defmodule Ganesha.Scheduling do
  @moduledoc """
  Multi-step schedule changes shared by the web UI and the LINE assistant
  (spec §4.1). Each function runs its steps in one transaction, so a change
  is never left half done.
  """

  alias Ganesha.{Repo, Roster, Studio}
  alias Ganesha.Roster.Credit
  alias Ganesha.Studio.{Session, Slot}

  @doc """
  Cancels a Session and issues one never-expiring Credit to every student
  seated in it. A Session is never left cancelled without its Credits, or
  the reverse. A blank reason returns the cancellation changeset.
  """
  @spec cancel_session(%Session{}, String.t() | nil) ::
          {:ok, %{session: %Session{}, credits: [%Credit{}]}} | {:error, Ecto.Changeset.t()}
  def cancel_session(%Session{} = session, reason) do
    Repo.transaction(fn ->
      case Studio.cancel_session(session, reason) do
        {:ok, cancelled} ->
          {:ok, credits} = Roster.issue_cancellation_credits(cancelled)
          %{session: cancelled, credits: credits}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Creates a weekly Slot and its Sessions for `month`. A Slot is never left
  without the month's Sessions it was created for.
  """
  @spec add_weekly_class(map(), Date.t()) ::
          {:ok, %{slot: %Slot{}, sessions: [%Session{}]}} | {:error, Ecto.Changeset.t()}
  def add_weekly_class(slot_attrs, %Date{} = month) do
    Repo.transaction(fn ->
      with {:ok, slot} <- Studio.create_slot(slot_attrs),
           {:ok, sessions} <- Studio.generate_month(slot, month) do
        %{slot: slot, sessions: sessions}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end

```

**Test:** `test/ganesha/scheduling_test.exs`

```elixir
defmodule Ganesha.SchedulingTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, People, Roster, Sales, Scheduling, Studio}

  @monday %{
    weekday: 1,
    start_time: ~T[09:30:00],
    end_time: ~T[10:45:00],
    default_style: "基礎",
    label: "早晨練習｜週一 基礎瑜伽"
  }

  defp seat_monthly(slot, session, name) do
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, package} =
      Catalog.create_package(%{name: "月課程 #{name}", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: package.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)
    student
  end

  describe "cancel_session/2" do
    test "cancels the session and issues a credit to each seated student" do
      {:ok, slot} = Studio.create_slot(@monday)
      {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
      lanzi = seat_monthly(slot, session, "蘭子")
      dandan = seat_monthly(slot, session, "丹丹")

      assert {:ok, %{session: cancelled, credits: credits}} =
               Scheduling.cancel_session(session, "颱風假")

      assert cancelled.state == "cancelled"
      assert cancelled.cancel_reason == "颱風假"
      assert Enum.sort(Enum.map(credits, & &1.student_id)) == Enum.sort([lanzi.id, dandan.id])
      assert Enum.all?(credits, &(&1.origin_session_id == session.id))
      assert Studio.get_session!(session.id).state == "cancelled"
    end

    test "without a reason returns the changeset and changes nothing" do
      {:ok, slot} = Studio.create_slot(@monday)
      {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
      lanzi = seat_monthly(slot, session, "蘭子")

      assert {:error, %Ecto.Changeset{} = changeset} = Scheduling.cancel_session(session, "")
      assert %{cancel_reason: [_]} = errors_on(changeset)
      assert Studio.get_session!(session.id).state == "scheduled"
      assert Roster.available_credits(lanzi.id, ~D[2026-12-01]) == []
    end
  end

  describe "add_weekly_class/2" do
    test "creates the slot and its sessions for the month" do
      assert {:ok, %{slot: slot, sessions: sessions}} =
               Scheduling.add_weekly_class(@monday, ~D[2026-08-01])

      # August 2026 Mondays.
      assert Enum.map(sessions, & &1.date) ==
               [~D[2026-08-03], ~D[2026-08-10], ~D[2026-08-17], ~D[2026-08-24], ~D[2026-08-31]]

      assert Enum.all?(sessions, &(&1.slot_id == slot.id and &1.style == "基礎"))
      assert Studio.list_active_slots() == [slot]
    end

    test "a weekday and time already taken returns the changeset and creates nothing" do
      {:ok, existing} = Studio.create_slot(@monday)

      assert {:error, %Ecto.Changeset{}} =
               Scheduling.add_weekly_class(
                 %{@monday | end_time: ~T[11:00:00], label: "另一堂課"},
                 ~D[2026-08-01]
               )

      assert Studio.list_slots() == [existing]
      assert Studio.sessions_in_month(~D[2026-08-01]) == []
    end
  end
end

```

**Modify** `lib/ganesha_web/live/month_live.ex`: alias `Scheduling`; replace the `"cancel"` handler body with `Scheduling.cancel_session/2` (flash strings unchanged).

**Modify** `lib/ganesha_web/live/schedule_live.ex`: alias `Scheduling`; replace `"create_recurring"` with `Scheduling.add_weekly_class/2`.

- [ ] **Step 1:** Add failing `test/ganesha/scheduling_test.exs` (below).
- [ ] **Step 2:** `mix test test/ganesha/scheduling_test.exs` — FAIL (module missing).
- [ ] **Step 3:** Add `lib/ganesha/scheduling.ex` (below) and wire LiveViews.
- [ ] **Step 4:** `mix test test/ganesha/scheduling_test.exs test/ganesha_web/live/month_live_test.exs test/ganesha_web/live/schedule_live_test.exs` — PASS.
- [ ] **Step 5:** `git add lib/ganesha/scheduling.ex test/ganesha/scheduling_test.exs lib/ganesha_web/live/month_live.ex lib/ganesha_web/live/schedule_live.ex && git commit -m "Add Scheduling and wire MonthLive and ScheduleLive"`


### Task 2: Credit and copy-month counts

**Modify** `lib/ganesha/roster.ex` — replace the `student_ids = Repo.all(from a in Attendance, ...)` block in `issue_cancellation_credits/1` with `credited_on_cancel/1`; add:

```elixir
  def cancellation_credit_count(%Session{} = session) do
    session |> credited_on_cancel() |> Repo.aggregate(:count)
  end

  defp credited_on_cancel(%Session{} = session) do
    from a in Attendance,
      where: a.session_id == ^session.id and a.kind in ^@cancelled_session_credit_kinds
  end
```

**Modify** `lib/ganesha/studio.ex` — insert after `copy_month/1`:

```elixir
  def count_new_sessions_for_month(%Date{} = month) do
    Enum.reduce(list_active_slots(), 0, fn slot, count ->
      existing = slot |> sessions_for_slot_in_month(month) |> MapSet.new(& &1.date)

      new_dates =
        month
        |> dates_in_month_on(slot.weekday)
        |> Enum.reject(&MapSet.member?(existing, &1))

      count + length(new_dates)
    end)
  end
```

- [ ] **Step 1:** Add `cancellation_credit_count/1` test via `cancel_session` task tests (Task 3).
- [ ] **Step 2:** Implement; `mix test test/ganesha/roster/credit_test.exs test/ganesha/studio_test.exs` — PASS.
- [ ] **Step 3:** `git add lib/ganesha/roster.ex lib/ganesha/studio.ex && git commit -m "Add schedule draft count helpers"`

---

### Task 3: `cancel_session`

**Create:** `lib/ganesha/assistant/tasks/cancel_session.ex`, `test/ganesha/assistant/tasks/cancel_session_test.exs`

```elixir
defmodule Ganesha.Assistant.Tasks.CancelSession do
  @moduledoc """
  `cancel_session` (spec §3.1 #7): cancels one Session and issues a Credit to
  everyone seated in it through `Ganesha.Scheduling.cancel_session/2`, the
  same call the web month page makes. A reason is required: students see it
  and it travels on their Credits, so the model must ask rather than invent.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Roster, Scheduling, Studio}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @apply_keys ~w(session_id reason)

  @impl true
  def name, do: "cancel_session"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Cancel one scheduled Session; every student booked in it gets a makeup Credit \
      (補課券). This only proposes a Draft; the Session is cancelled when the teacher taps \
      Confirm. A reason is required and students see it: use her words (颱風假, 老師生病). \
      If she has not said why, ask her first; never invent a reason. Use a session id from \
      the studio snapshot.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          session_id: %{type: "integer"},
          reason: %{
            type: "string",
            description: "Why the Session is cancelled, in the teacher's words"
          }
        },
        required: ["session_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, session} <- fetch_session(input["session_id"]),
         :ok <- check_scheduled(session),
         {:ok, reason} <- check_reason(input["reason"]) do
      parsed = %{
        "session_id" => session.id,
        "reason" => reason,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "credit_count" => Roster.cancellation_credit_count(session)
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, session} <- load_session(attrs["session_id"]),
         :ok <- still_scheduled(session),
         :ok <- same_credit_count(session, parsed["credit_count"]),
         {:ok, %{session: cancelled}} <- Scheduling.cancel_session(session, attrs["reason"]) do
      {:ok, {"Ganesha.Studio.Session", cancelled.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title: "#{title(locale)} #{short_date(date)} #{parsed["session_label"]}",
      lines:
        Enum.reject(
          [session_line(parsed, date, locale), reason_line(parsed["reason"], locale)],
          &is_nil/1
        ),
      changes: [state_change(locale) | credit_change(parsed["credit_count"], locale)],
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp fetch_session(id) when is_integer(id) do
    case Studio.get_session(id) do
      nil -> {:error, "no session with id #{id}; use a session id from the snapshot"}
      session -> {:ok, session}
    end
  end

  defp fetch_session(_id), do: {:error, "session_id must be a session id from the snapshot"}

  defp load_session(id) when is_integer(id) do
    case Studio.get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp load_session(_id), do: {:error, :not_found}

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is already cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> missing_reason()
      trimmed -> {:ok, trimmed}
    end
  end

  defp check_reason(_reason), do: missing_reason()

  defp missing_reason,
    do:
      {:error,
       "a cancellation needs a reason, and students will see it; " <>
         "ask the teacher why the Session is cancelled"}

  # The card promised this many Credits; a roster change since then would
  # issue a different number, so the teacher must see a fresh card.
  defp same_credit_count(session, count) do
    if Roster.cancellation_credit_count(session) == count,
      do: :ok,
      else: {:error, :roster_changed}
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  defp short_date(nil), do: ""
  defp short_date(date), do: Fmt.short_date(date)

  defp title("en"), do: "Cancel"
  defp title(_locale), do: "停課"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Format.session_day(date, "en")} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, locale),
    do:
      "課堂：#{Format.session_day(date, locale)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp reason_line(reason, _locale) when reason in [nil, ""], do: nil
  defp reason_line(reason, "en"), do: "Reason: #{reason}"
  defp reason_line(reason, _locale), do: "原因：#{reason}"

  defp state_change("en"), do: {"Status", "Scheduled", "Cancelled"}
  defp state_change(_locale), do: {"狀態", "上課", "停課"}

  defp credit_change(count, "en") when is_integer(count),
    do: [{"Makeup credits", nil, "#{count} issued"}]

  defp credit_change(count, _locale) when is_integer(count),
    do: [{"補課券", nil, "發出 #{count} 張"}]

  defp credit_change(_count, _locale), do: []
end

```

```elixir
defmodule Ganesha.Assistant.Tasks.CancelSessionTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Tasks.CancelSession

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 3,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, student} = People.create_student(%{display_name: "蘭子"})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: package.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      session: session,
      student: student,
      purchase: purchase
    }
  end

  describe "propose/2" do
    test "captures the reason and how many credits the card will issue", c do
      assert {:ok, %{student_id: nil, parsed: parsed}} =
               CancelSession.propose(
                 %{"session_id" => c.session.id, "reason" => " 颱風假 "},
                 c.ctx
               )

      assert parsed["reason"] == "颱風假"
      assert parsed["credit_count"] == 1
      assert parsed["session_date"] == "2026-10-07"
      assert Studio.get_session!(c.session.id).state == "scheduled"
    end

    test "rejects a missing reason so the model asks the teacher", c do
      assert {:error, message} =
               CancelSession.propose(%{"session_id" => c.session.id, "reason" => ""}, c.ctx)

      assert message =~ "ask the teacher"
    end

    test "rejects an already cancelled session", c do
      {:ok, _} = Studio.cancel_session(c.session, "already")

      assert {:error, message} =
               CancelSession.propose(
                 %{"session_id" => c.session.id, "reason" => "颱風假"},
                 c.ctx
               )

      assert message =~ "already cancelled"
    end
  end

  describe "apply/2" do
    test "cancels the session and issues credits", c do
      {:ok, %{parsed: parsed}} =
        CancelSession.propose(
          %{"session_id" => c.session.id, "reason" => "颱風假"},
          c.ctx
        )

      assert {:ok, {"Ganesha.Studio.Session", session_id}} =
               CancelSession.apply(parsed, "line:teacher")

      assert session_id == c.session.id
      assert Studio.get_session!(c.session.id).state == "cancelled"
      assert [_credit] = Roster.available_credits(c.student.id, ~D[2026-12-01])
    end

    test "fails if the session was cancelled after the Draft was made", c do
      {:ok, %{parsed: parsed}} =
        CancelSession.propose(
          %{"session_id" => c.session.id, "reason" => "颱風假"},
          c.ctx
        )

      {:ok, _} = Studio.cancel_session(c.session, "already")

      assert {:error, :session_cancelled} = CancelSession.apply(parsed, "line:teacher")
      assert Roster.available_credits(c.student.id, ~D[2026-12-01]) == []
    end

    test "fails if the roster changed after the Draft was made", c do
      {:ok, %{parsed: parsed}} =
        CancelSession.propose(
          %{"session_id" => c.session.id, "reason" => "颱風假"},
          c.ctx
        )

      {:ok, student2} = People.create_student(%{display_name: "丹丹"})

      {:ok, _} = Roster.enroll(c.session, student2, c.purchase)

      assert {:error, :roster_changed} = CancelSession.apply(parsed, "line:teacher")
      assert Studio.get_session!(c.session.id).state == "scheduled"
    end
  end

  describe "describe/2" do
    test "shows the session, reason and credit count from parsed only", c do
      {:ok, %{parsed: parsed}} =
        CancelSession.propose(
          %{"session_id" => c.session.id, "reason" => "颱風假"},
          c.ctx
        )

      assert %{
               title: "停課 10/7 基礎",
               lines: ["課堂：10/7 週三 基礎 19:00–20:15", "原因：颱風假"],
               changes: [
                 {"狀態", "上課", "停課"},
                 {"補課券", nil, "發出 1 張"}
               ],
               web_path: web_path
             } = CancelSession.describe(parsed, "zh-TW")

      assert web_path == "/sessions/#{c.session.id}"
    end
  end
end

```

- [ ] **Step 1:** Failing test file above.
- [ ] **Step 2:** `mix test test/ganesha/assistant/tasks/cancel_session_test.exs` — FAIL.
- [ ] **Step 3:** Implement module above.
- [ ] **Step 4:** Test PASS; `mix compile --warnings-as-errors` clean.
- [ ] **Step 5:** `git add lib/ganesha/assistant/tasks/cancel_session.ex test/ganesha/assistant/tasks/cancel_session_test.exs && git commit -m "Add cancel_session LINE task"`

---

### Task 4: `set_session_style`

**Create:** `lib/ganesha/assistant/tasks/set_session_style.ex`, `test/ganesha/assistant/tasks/set_session_style_test.exs`

```elixir
defmodule Ganesha.Assistant.Tasks.SetSessionStyle do
  @moduledoc """
  `set_session_style` (spec §3.1 #8): changes one Session's style through
  `Ganesha.Studio.set_style/2`, the same call the web month page makes.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Studio
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @apply_keys ~w(session_id style)

  @impl true
  def name, do: "set_session_style"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Change the style (課型) of one scheduled Session for a single date. This only \
      proposes a Draft; the style changes when the teacher taps Confirm. Use a session id \
      from the studio snapshot.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          session_id: %{type: "integer"},
          style: %{type: "string", description: "The new style for this Session only"}
        },
        required: ["session_id", "style"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, session} <- fetch_session(input["session_id"]),
         :ok <- check_scheduled(session),
         {:ok, style} <- check_style(input["style"]) do
      parsed = %{
        "session_id" => session.id,
        "style" => style,
        "before_style" => session.style,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session)
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, session} <- load_session(attrs["session_id"]),
         :ok <- still_scheduled(session),
         :ok <- same_style(session, parsed["before_style"]),
         {:ok, updated} <- Studio.set_style(session, attrs["style"]) do
      {:ok, {"Ganesha.Studio.Session", updated.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title: "#{title(locale)} #{short_date(date)} #{parsed["session_label"]}",
      lines: [session_line(parsed, date, locale)],
      changes: [
        {style_label(locale), parsed["before_style"], parsed["style"]}
      ],
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp fetch_session(id) when is_integer(id) do
    case Studio.get_session(id) do
      nil -> {:error, "no session with id #{id}; use a session id from the snapshot"}
      session -> {:ok, session}
    end
  end

  defp fetch_session(_id), do: {:error, "session_id must be a session id from the snapshot"}

  defp load_session(id) when is_integer(id) do
    case Studio.get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  defp load_session(_id), do: {:error, :not_found}

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_style(style) when is_binary(style) do
    case String.trim(style) do
      "" -> {:error, "style must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp check_style(_style), do: {:error, "style must be a string"}

  defp same_style(%{style: current}, before) when is_binary(before) do
    if current == before, do: :ok, else: {:error, :style_changed}
  end

  defp same_style(_session, _before), do: {:error, :style_changed}

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  defp short_date(nil), do: ""
  defp short_date(date), do: Fmt.short_date(date)

  defp title("en"), do: "Style"
  defp title(_locale), do: "課型"

  defp style_label("en"), do: "Style"
  defp style_label(_locale), do: "課型"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Format.session_day(date, "en")} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, locale),
    do:
      "課堂：#{Format.session_day(date, locale)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"
end

```

```elixir
defmodule Ganesha.Assistant.Tasks.SetSessionStyleTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Tasks.SetSessionStyle

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 3,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}, session: session}
  end

  test "captures before_style and updates on apply", %{ctx: ctx, session: session} do
    assert {:ok, %{parsed: parsed}} =
             SetSessionStyle.propose(
               %{"session_id" => session.id, "style" => "流動"},
               ctx
             )

    assert parsed["before_style"] == "Hatha"

    assert {:ok, {"Ganesha.Studio.Session", id}} =
             SetSessionStyle.apply(parsed, "line:teacher")

    assert id == session.id
    assert Studio.get_session!(session.id).style == "流動"
  end

  test "apply fails when the style changed after propose", %{ctx: ctx, session: session} do
    {:ok, %{parsed: parsed}} =
      SetSessionStyle.propose(%{"session_id" => session.id, "style" => "流動"}, ctx)

    {:ok, _} = Studio.set_style(session, "其他")

    assert {:error, :style_changed} = SetSessionStyle.apply(parsed, "line:teacher")
  end
end

```

- [ ] **Step 1:** Failing test file above.
- [ ] **Step 2:** `mix test test/ganesha/assistant/tasks/set_session_style_test.exs` — FAIL.
- [ ] **Step 3:** Implement module above.
- [ ] **Step 4:** Test PASS; `mix compile --warnings-as-errors` clean.
- [ ] **Step 5:** `git add lib/ganesha/assistant/tasks/set_session_style.ex test/ganesha/assistant/tasks/set_session_style_test.exs && git commit -m "Add set_session_style LINE task"`

---

### Task 5: `add_session`

**Create:** `lib/ganesha/assistant/tasks/add_session.ex`, `test/ganesha/assistant/tasks/add_session_test.exs`

```elixir
defmodule Ganesha.Assistant.Tasks.AddSession do
  @moduledoc """
  `add_session` (spec §3.1 #9): creates one standalone Session through
  `Ganesha.Studio.create_session/1`, the same call the web schedule page uses
  for a one-off class.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Studio
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "add_session"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Schedule one standalone Session on a date (not a recurring Slot). This only \
      proposes a Draft; the Session is created when the teacher taps Confirm. Use ISO \
      dates and HH:MM:SS times.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          date: %{type: "string", description: "ISO 8601 date"},
          start_time: %{type: "string", description: "HH:MM:SS"},
          end_time: %{type: "string", description: "HH:MM:SS"},
          label: %{type: "string", description: "Class name shown to students"},
          style: %{type: "string", description: "Style (課型) for this Session"}
        },
        required: ["date", "start_time", "end_time", "label", "style"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, attrs} <- build_attrs(input),
         :ok <- check_no_conflict(attrs) do
      parsed =
        Map.merge(attrs, %{
          "date" => Date.to_iso8601(attrs["date"]),
          "start_time" => Time.to_string(attrs["start_time"]),
          "end_time" => Time.to_string(attrs["end_time"])
        })

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    with {:ok, attrs} <- build_attrs(parsed),
         :ok <- check_no_conflict(attrs),
         {:ok, session} <-
           Studio.create_session(
             Map.merge(attrs, %{
               "state" => "scheduled",
               "slot_id" => nil
             })
           ) do
      {:ok, {"Ganesha.Studio.Session", session.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["date"])

    %{
      title: "#{title(locale)} #{parsed["label"]}",
      lines:
        Enum.reject(
          [
            date_line(date, locale),
            time_line(parsed["start_time"], parsed["end_time"], locale),
            style_line(parsed["style"], locale)
          ],
          &is_nil/1
        ),
      changes: [{session_label(locale), nil, parsed["label"]}],
      web_path: month_path(date)
    }
  end

  defp build_attrs(input) do
    with {:ok, date} <- parse_required_date(input["date"]),
         {:ok, start_time} <- parse_required_time(input["start_time"]),
         {:ok, end_time} <- parse_required_time(input["end_time"]),
         {:ok, label} <- parse_required_string(input["label"], "label"),
         {:ok, style} <- parse_required_string(input["style"], "style"),
         :ok <- check_time_order(start_time, end_time) do
      {:ok,
       %{
         "date" => date,
         "start_time" => start_time,
         "end_time" => end_time,
         "label" => label,
         "style" => style
       }}
    end
  end

  defp check_no_conflict(%{"date" => date, "start_time" => start_time, "label" => label}) do
    conflict? =
      date
      |> Studio.sessions_in_month()
      |> Enum.any?(fn session ->
        session.slot_id == nil and session.date == date and session.start_time == start_time and
          session.label == label
      end)

    if conflict?, do: {:error, :duplicate_session}, else: :ok
  end

  defp parse_required_date(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "date must be an ISO 8601 date like 2026-10-20"}
    end
  end

  defp parse_required_date(_text), do: {:error, "date must be an ISO 8601 date like 2026-10-20"}

  defp parse_required_time(text) when is_binary(text) do
    case Time.from_iso8601(normalize_time(text)) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> {:error, "start_time and end_time must be HH:MM:SS like 19:00:00"}
    end
  end

  defp parse_required_time(_text),
    do: {:error, "start_time and end_time must be HH:MM:SS like 19:00:00"}

  defp normalize_time(hm) when is_binary(hm) and byte_size(hm) == 5, do: hm <> ":00"
  defp normalize_time(other), do: other

  defp parse_required_string(text, field) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "#{field} must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_required_string(_text, field), do: {:error, "#{field} must be a string"}

  defp check_time_order(start_time, end_time) do
    if Time.compare(start_time, end_time) == :lt,
      do: :ok,
      else: {:error, "end_time must be after start_time"}
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  defp month_path(nil), do: nil

  defp month_path(%Date{} = date), do: "/class/#{date.year}/#{date.month}"

  defp title("en"), do: "Add session"
  defp title(_locale), do: "排課"

  defp session_label("en"), do: "Session"
  defp session_label(_locale), do: "課堂"

  defp date_line(nil, _locale), do: nil
  defp date_line(date, "en"), do: "Date: #{Format.session_day(date, "en")}"
  defp date_line(date, locale), do: "日期：#{Format.session_day(date, locale)}"

  defp time_line(start, stop, _locale) when start in [nil, ""] or stop in [nil, ""], do: nil

  defp time_line(start, stop, "en"),
    do: "Time: #{Fmt.time_range(parse_time!(start), parse_time!(stop))}"

  defp time_line(start, stop, _locale),
    do: "時間：#{Fmt.time_range(parse_time!(start), parse_time!(stop))}"

  defp style_line(style, _locale) when style in [nil, ""], do: nil
  defp style_line(style, "en"), do: "Style: #{style}"
  defp style_line(style, _locale), do: "課型：#{style}"

  defp parse_time!(iso) do
    {:ok, time} = Time.from_iso8601(normalize_time(iso))
    time
  end
end

```

```elixir
defmodule Ganesha.Assistant.Tasks.AddSessionTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Tasks.AddSession

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "creates a standalone session on apply", %{ctx: ctx} do
    input = %{
      "date" => "2026-10-20",
      "start_time" => "19:00:00",
      "end_time" => "20:00:00",
      "label" => "期間限定",
      "style" => "流動"
    }

    assert {:ok, %{parsed: parsed}} = AddSession.propose(input, ctx)

    assert {:ok, {"Ganesha.Studio.Session", session_id}} =
             AddSession.apply(parsed, "line:teacher")

    session = Studio.get_session!(session_id)
    assert session.slot_id == nil
    assert session.label == "期間限定"
  end
end

```

- [ ] **Step 1:** Failing test file above.
- [ ] **Step 2:** `mix test test/ganesha/assistant/tasks/add_session_test.exs` — FAIL.
- [ ] **Step 3:** Implement module above.
- [ ] **Step 4:** Test PASS; `mix compile --warnings-as-errors` clean.
- [ ] **Step 5:** `git add lib/ganesha/assistant/tasks/add_session.ex test/ganesha/assistant/tasks/add_session_test.exs && git commit -m "Add add_session LINE task"`

---

### Task 6: `add_slot`

**Create:** `lib/ganesha/assistant/tasks/add_slot.ex`, `test/ganesha/assistant/tasks/add_slot_test.exs`

```elixir
defmodule Ganesha.Assistant.Tasks.AddSlot do
  @moduledoc """
  `add_slot` (spec §3.1 #10): creates a weekly Slot and its Sessions for one
  month through `Ganesha.Scheduling.add_weekly_class/2`, the same call the web
  schedule page makes for a recurring class.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Scheduling, Studio}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "add_slot"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Create a new weekly Slot (固定班) and generate its Sessions for one month. This only \
      proposes a Draft; the Slot and Sessions are created when the teacher taps Confirm. \
      Weekday is 1=Monday … 7=Sunday; times are HH:MM:SS. Use month as the first day of the \
      month to generate (ISO 8601).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          weekday: %{type: "integer", minimum: 1, maximum: 7},
          start_time: %{type: "string", description: "HH:MM:SS"},
          end_time: %{type: "string", description: "HH:MM:SS"},
          label: %{type: "string"},
          default_style: %{type: "string", description: "Default style for each Session"},
          month: %{type: "string", description: "First day of the month to generate, ISO 8601"}
        },
        required: ["weekday", "start_time", "end_time", "label", "default_style", "month"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, attrs, month} <- build_attrs(input),
         :ok <- check_slot_available(attrs) do
      session_count = session_count(attrs, month)

      parsed =
        Map.merge(attrs, %{
          "month" => Date.to_iso8601(month),
          "start_time" => Time.to_string(attrs["start_time"]),
          "end_time" => Time.to_string(attrs["end_time"]),
          "session_count" => session_count
        })

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    with {:ok, slot_attrs, month} <- build_slot_attrs(parsed),
         :ok <- check_slot_available(slot_attrs),
         :ok <- same_session_count(slot_attrs, month, parsed["session_count"]),
         {:ok, %{slot: slot, sessions: _sessions}} <-
           Scheduling.add_weekly_class(Map.put(slot_attrs, "active", true), month) do
      {:ok, {"Ganesha.Studio.Slot", slot.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    month = parse_date(parsed["month"])

    %{
      title: "#{title(locale)} #{parsed["label"]}",
      lines:
        Enum.reject(
          [
            weekday_line(parsed["weekday"], locale),
            time_line(parsed["start_time"], parsed["end_time"], locale),
            month_line(month, locale),
            style_line(parsed["default_style"], locale)
          ],
          &is_nil/1
        ),
      changes: [session_change(parsed["session_count"], locale)],
      web_path: month && "/class/#{month.year}/#{month.month}"
    }
  end

  defp build_attrs(input) do
    with {:ok, weekday} <- parse_weekday(input["weekday"]),
         {:ok, start_time} <- parse_time(input["start_time"]),
         {:ok, end_time} <- parse_time(input["end_time"]),
         {:ok, label} <- parse_string(input["label"], "label"),
         {:ok, default_style} <- parse_string(input["default_style"], "default_style"),
         {:ok, month} <- parse_month(input["month"]),
         :ok <- check_time_order(start_time, end_time) do
      {:ok,
       %{
         "weekday" => weekday,
         "start_time" => start_time,
         "end_time" => end_time,
         "label" => label,
         "default_style" => default_style
       }, month}
    end
  end

  defp build_slot_attrs(parsed) do
    with {:ok, attrs, month} <- build_attrs(parsed) do
      {:ok, attrs, month}
    end
  end

  defp check_slot_available(attrs) do
    taken? =
      Studio.list_slots()
      |> Enum.any?(
        &(&1.weekday == attrs["weekday"] and &1.start_time == attrs["start_time"] and &1.active)
      )

    if taken?, do: {:error, :slot_taken}, else: :ok
  end

  defp session_count(attrs, month) do
    month
    |> dates_on_weekday(attrs["weekday"])
    |> length()
  end

  defp same_session_count(attrs, month, count) do
    if session_count(attrs, month) == count, do: :ok, else: {:error, :month_changed}
  end

  defp dates_on_weekday(%Date{} = month, weekday) do
    month
    |> Date.range(Ganesha.Clock.end_of_month(month))
    |> Enum.filter(&(Date.day_of_week(&1) == weekday))
  end

  defp parse_weekday(n) when is_integer(n) and n in 1..7, do: {:ok, n}
  defp parse_weekday(_n), do: {:error, "weekday must be 1 (Monday) through 7 (Sunday)"}

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, Date.beginning_of_month(date)}
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  defp parse_time(text), do: parse_time_field(text, "start_time and end_time")

  defp parse_time_field(text, field) when is_binary(text) do
    case Time.from_iso8601(normalize_time(text)) do
      {:ok, time} -> {:ok, time}
      {:error, _} -> {:error, "#{field} must be HH:MM:SS like 19:00:00"}
    end
  end

  defp parse_time_field(_text, field), do: {:error, "#{field} must be HH:MM:SS like 19:00:00"}

  defp normalize_time(hm) when is_binary(hm) and byte_size(hm) == 5, do: hm <> ":00"
  defp normalize_time(other), do: other

  defp parse_string(text, field) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "#{field} must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_string(_text, field), do: {:error, "#{field} must be a string"}

  defp check_time_order(start_time, end_time) do
    if Time.compare(start_time, end_time) == :lt,
      do: :ok,
      else: {:error, "end_time must be after start_time"}
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  defp title("en"), do: "New weekly class"
  defp title(_locale), do: "固定班次"

  defp weekday_line(weekday, "en") when is_integer(weekday),
    do: "Weekday: #{weekday_en(weekday)}"

  defp weekday_line(weekday, _locale) when is_integer(weekday),
    do: "星期：#{Fmt.weekday(weekday)}"

  defp time_line(start, stop, _locale) when start in [nil, ""] or stop in [nil, ""], do: nil

  defp time_line(start, stop, "en"),
    do: "Time: #{Fmt.time_range(parse_time!(start), parse_time!(stop))}"

  defp time_line(start, stop, _locale),
    do: "時間：#{Fmt.time_range(parse_time!(start), parse_time!(stop))}"

  defp month_line(nil, _locale), do: nil
  defp month_line(month, "en"), do: "Month: #{Format.month_title(month, "en")}"
  defp month_line(month, locale), do: "月份：#{Format.month_title(month, locale)}"

  defp style_line(style, _locale) when style in [nil, ""], do: nil
  defp style_line(style, "en"), do: "Style: #{style}"
  defp style_line(style, _locale), do: "課型：#{style}"

  defp session_change(count, "en") when is_integer(count),
    do: {"Sessions", nil, "#{count} scheduled"}

  defp session_change(count, _locale) when is_integer(count),
    do: {"課堂", nil, "排 #{count} 堂"}

  defp session_change(_count, _locale), do: {"課堂", nil, "—"}

  defp weekday_en(weekday) when weekday in 1..7,
    do: Date.add(~D[2024-01-01], weekday - 1) |> Calendar.strftime("%a")

  defp parse_time!(iso) do
    {:ok, time} = Time.from_iso8601(normalize_time(iso))
    time
  end
end

```

```elixir
defmodule Ganesha.Assistant.Tasks.AddSlotTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Tasks.AddSlot

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "creates the slot and august sessions", %{ctx: ctx} do
    input = %{
      "weekday" => 1,
      "start_time" => "09:30:00",
      "end_time" => "10:45:00",
      "label" => "早晨練習｜週一 基礎瑜伽",
      "default_style" => "基礎",
      "month" => "2026-08-01"
    }

    assert {:ok, %{parsed: parsed}} = AddSlot.propose(input, ctx)
    assert parsed["session_count"] == 5

    assert {:ok, {"Ganesha.Studio.Slot", slot_id}} = AddSlot.apply(parsed, "line:teacher")
    slot = Studio.get_slot!(slot_id)
    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01])) == 5
  end
end

```

- [ ] **Step 1:** Failing test file above.
- [ ] **Step 2:** `mix test test/ganesha/assistant/tasks/add_slot_test.exs` — FAIL.
- [ ] **Step 3:** Implement module above.
- [ ] **Step 4:** Test PASS; `mix compile --warnings-as-errors` clean.
- [ ] **Step 5:** `git add lib/ganesha/assistant/tasks/add_slot.ex test/ganesha/assistant/tasks/add_slot_test.exs && git commit -m "Add add_slot LINE task"`

---

### Task 7: `copy_month`

**Create:** `lib/ganesha/assistant/tasks/copy_month.ex`, `test/ganesha/assistant/tasks/copy_month_test.exs`

```elixir
defmodule Ganesha.Assistant.Tasks.CopyMonth do
  @moduledoc """
  `copy_month` (spec §3.1 #11): copies every active Slot's schedule into a
  month through `Ganesha.Studio.copy_month/1`, the same call the web month
  page's copy prompt uses.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Studio
  alias Ganesha.Assistant.Format

  @impl true
  def name, do: "copy_month"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Copy every active weekly Slot's Sessions into a month (same as the web "copy last \
      month's schedule" prompt). This only proposes a Draft; Sessions are created when the \
      teacher taps Confirm. Pass month as the first day of the target month (ISO 8601).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{type: "string", description: "Target month, ISO 8601 date like 2026-10-01"}
        },
        required: ["month"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, month} <- parse_month(input["month"]) do
      parsed = %{
        "month" => Date.to_iso8601(month),
        "session_count" => Studio.count_new_sessions_for_month(month)
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    with {:ok, month} <- parse_month(parsed["month"]),
         :ok <- same_count(month, parsed["session_count"]),
         {:ok, created} <- Studio.copy_month(month) do
      {:ok, {nil, created}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    month = parse_date(parsed["month"])

    %{
      title: title(month, locale),
      lines: [],
      changes: [session_change(parsed["session_count"], locale)],
      web_path: month && "/class/#{month.year}/#{month.month}"
    }
  end

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, Date.beginning_of_month(date)}
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  defp same_count(month, count) do
    if Studio.count_new_sessions_for_month(month) == count,
      do: :ok,
      else: {:error, :schedule_changed}
  end

  defp title(nil, _locale), do: "Copy month"
  defp title(month, "en"), do: "Copy schedule into #{Format.month_title(month, "en")}"
  defp title(month, _locale), do: "複製課表至 #{Format.month_title(month, "zh-TW")}"

  defp session_change(count, "en") when is_integer(count),
    do: {"Sessions", nil, "#{count} to create"}

  defp session_change(count, _locale) when is_integer(count),
    do: {"課堂", nil, "將建立 #{count} 堂"}

  defp session_change(_count, _locale), do: {"課堂", nil, "—"}
end

```

```elixir
defmodule Ganesha.Assistant.Tasks.CopyMonthTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Tasks.CopyMonth

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "copy_month creates the promised number of sessions", %{ctx: ctx} do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:ok, %{parsed: parsed}} =
             CopyMonth.propose(%{"month" => "2026-09-01"}, ctx)

    assert parsed["session_count"] == 4
    assert {:ok, {nil, 4}} = CopyMonth.apply(parsed, "line:teacher")
    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-09-01])) == 4
  end
end

```

- [ ] **Step 1:** Failing test file above.
- [ ] **Step 2:** `mix test test/ganesha/assistant/tasks/copy_month_test.exs` — FAIL.
- [ ] **Step 3:** Implement module above.
- [ ] **Step 4:** Test PASS; `mix compile --warnings-as-errors` clean.
- [ ] **Step 5:** `git add lib/ganesha/assistant/tasks/copy_month.ex test/ganesha/assistant/tasks/copy_month_test.exs && git commit -m "Add copy_month LINE task"`

---

### Task 8: Registry and conversation tool list

**Modify:** `lib/ganesha/assistant/tasks.ex`

```elixir
defmodule Ganesha.Assistant.Tasks do
  @moduledoc """
  Which chat gets which tasks (spec §2 rule 7), lookup by name, and the tool
  schemas the model sees (spec §4.2). Schemas use the atom-keyed shape
  `Ganesha.Assistant.Provider.Anthropic` sends: `name`, `description`,
  `input_schema`.
  """

  alias Ganesha.Assistant.Tasks.{
    AddSession,
    AddSlot,
    AskTeacher,
    BookOneOff,
    CancelSession,
    CopyMonth,
    MakeupRequest,
    RecordPayment,
    SetLanguage,
    SetSessionStyle
  }

  @teacher [
    RecordPayment,
    BookOneOff,
    MakeupRequest,
    CancelSession,
    SetSessionStyle,
    AddSession,
    AddSlot,
    CopyMonth,
    AskTeacher,
    SetLanguage
  ]
  @group [RecordPayment, BookOneOff, MakeupRequest]
  @student [SetLanguage]

  @spec for_chat(:teacher | :group | :student) :: [module()]
  def for_chat(:teacher), do: @teacher
  def for_chat(:group), do: @group
  def for_chat(:student), do: @student

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(all(), &(&1.name() == name)) do
      nil -> :error
      task -> {:ok, task}
    end
  end

  def fetch(_name), do: :error

  @spec tool_schemas([module()]) :: [map()]
  def tool_schemas(tasks) do
    Enum.map(tasks, fn task ->
      %{description: description, input_schema: input_schema} = task.tool()

      %{
        name: task.name(),
        description: description,
        input_schema: add_shared_fields(input_schema, task.kind())
      }
    end)
  end

  defp all, do: Enum.uniq(@teacher ++ @group ++ @student)

  defp add_shared_fields(schema, :change) do
    put_property(schema, :replaces_draft_id, %{
      type: "integer",
      description: "When correcting a pending Draft, that Draft's id; the old Draft is replaced."
    })
  end

  defp add_shared_fields(schema, :lookup) do
    put_property(schema, :show_card, %{
      type: "boolean",
      description: "true to also show the teacher this answer as a card."
    })
  end

  defp add_shared_fields(schema, :control), do: schema

  defp put_property(schema, key, property) do
    Map.update(schema, :properties, %{key => property}, &Map.put(&1, key, property))
  end
end

```

**Modify** `test/ganesha/assistant/tasks_test.exs`: keep slice 2's membership style; add:

```elixir
alias Ganesha.Assistant.Tasks.{
  AddSession,
  AddSlot,
  CancelSession,
  CopyMonth,
  SetSessionStyle,
  ...
}

test "the five schedule change tasks are Teacher-only" do
  teacher = Tasks.for_chat(:teacher)
  group = Tasks.for_chat(:group)
  student = Tasks.for_chat(:student)

  for task <- [CancelSession, SetSessionStyle, AddSession, AddSlot, CopyMonth] do
    assert task in teacher
    refute task in group
    refute task in student
    assert task.kind() == :change
  end
end
```

**Modify** `test/ganesha/assistant/conversation_test.exs` (~line 154): replace the exact tool-name list with:

```elixir
      names = Enum.map(request.tools, & &1.name)

      for expected <-
            ~w(record_payment book_one_off makeup_request cancel_session set_session_style add_session add_slot copy_month ask_teacher set_language) do
        assert expected in names
      end
```

(Slice 2 adds six lookup tools to `@teacher` before this lands; extend the `~w(...)` list with those six names when they exist, same membership style.)

- [ ] Commit registry + tests.

---

### Task 9: Real Sonnet run and precommit

**Create** `priv/scripts/line_real_schedule.exs` — same setup as `line_real_turn.exs` (`.env.dev`, `Line.Client.Mock`, SMOKE cleanup) but seeds a Monday slot + October session, then runs two turns:

1. Teacher message without a reason → expect model to ask or tool error, no cancel applied.
2. Teacher message with reason → `cancel_session` Draft; confirm via `Assistant.confirm_draft/2` or postback stub.
3. Third message changing style → `set_session_style` Draft.

Print Turn, Drafts, and `Reply.build/3` JSON like `line_real_turn.exs`.

**Create:** `priv/scripts/line_real_schedule.exs`

```elixir
#!/usr/bin/env elixir
# Real Teacher chat turns for schedule tasks (spec §8 slice 3).
#
#     mix ecto.migrate
#     source .env.dev && mix run priv/scripts/line_real_schedule.exs
#
# Uses Anthropic + Line.Client.Mock. Seeds SMOKE schedule data, runs three
# Conversation turns (cancel without reason, cancel with reason, style change).

import Ecto.Query

alias Ganesha.{Assistant, Catalog, People, Repo, Roster, Sales, Studio}
alias Ganesha.Assistant.{Conversation, Draft, Message, Thread}
alias Ganesha.Line.Reply

Logger.configure(level: :warning)
Application.put_env(:ganesha, :line_client, Ganesha.Line.Client.Mock)

provider = Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider)

api_key =
  :ganesha
  |> Application.get_env(Ganesha.Assistant.Provider.Anthropic, [])
  |> Keyword.get(:api_key, "")

if provider != Ganesha.Assistant.Provider.Anthropic or api_key == "" do
  IO.puts("Needs the dev Anthropic provider and ANTHROPIC_API_KEY: run `source .env.dev` first.")
  System.halt(1)
end

teacher_id = "Usmokesched0000000000000000"

cleanup = fn ->
  session_ids =
    from(s in Studio.Session,
      join: sl in assoc(s, :slot),
      where: like(sl.label, "SMOKE%"),
      select: s.id
    )

  thread_ids = from(t in Thread, where: t.source_id == ^teacher_id, select: t.id)

  Repo.delete_all(from(c in Ganesha.Roster.Credit, where: c.origin_session_id in subquery(session_ids)))
  Repo.delete_all(from(a in Ganesha.Roster.Attendance, where: a.session_id in subquery(session_ids)))
  Repo.delete_all(from(s in Studio.Session, where: s.id in subquery(session_ids)))
  Repo.delete_all(from(sl in Studio.Slot, where: like(sl.label, "SMOKE%")))
  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id == ^teacher_id))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))
end

run_turn = fn thread, text ->
  IO.puts("\nTeacher: #{text}\n")
  {:ok, _} = Assistant.append_message(thread, "user", text, nil)

  case Conversation.run_turn(thread) do
    {:ok, turn} ->
      drafts = Assistant.get_drafts(turn.draft_ids)
      IO.puts("== Turn")
      IO.inspect(turn, pretty: true, charlists: :as_lists)
      IO.puts("\n== Drafts")

      Enum.each(
        drafts,
        &IO.inspect(Map.take(&1, [:id, :kind, :state, :student_id, :parsed]), pretty: true)
      )

      IO.puts("\n== LINE messages")
      IO.puts(Jason.encode!(Reply.build(turn, drafts, "zh-TW"), pretty: true))
      {thread, turn, drafts}

    {:error, reason} ->
      IO.puts("Agent failed: #{inspect(reason)}")
      System.halt(1)
  end
end

cleanup.()

{:ok, slot} =
  Studio.create_slot(%{
    weekday: 3,
    start_time: ~T[19:00:00],
    end_time: ~T[20:15:00],
    default_style: "Hatha",
    label: "SMOKE 基礎"
  })

{:ok, session} =
  Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha", state: "scheduled"})

{:ok, style_session} =
  Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-14], style: "Hatha", state: "scheduled"})

{:ok, student} = People.create_student(%{display_name: "SMOKE 蘭子"})

{:ok, package} =
  Catalog.create_package(%{name: "SMOKE 月課程", kind: "monthly", price_per_class: 400})

{:ok, purchase} =
  Sales.create_purchase(%{
    student_id: student.id,
    package_id: package.id,
    slot_id: slot.id,
    list_price: 2000
  })

{:ok, _} = Roster.enroll(session, student, purchase)

{:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, thread} = Assistant.set_locale(thread, "zh-TW")

{thread, _turn, drafts1} =
  run_turn.(thread, "SMOKE 把 10/7 那堂基礎課停掉")

if Enum.any?(drafts1, &(&1.kind == "cancel_session" and &1.state == "pending")) do
  IO.puts("\n(Warning: model proposed cancel without a stated reason — check parsed.reason)\n")
end

{thread, turn2, drafts2} =
  run_turn.(thread, "SMOKE 停課，原因是颱風假，session #{session.id}")

case Enum.find(drafts2, &(&1.kind == "cancel_session")) do
  %Draft{} = draft ->
case Assistant.confirm_draft(draft, "line:teacher") do
  {:ok, _} ->
    IO.puts("Confirmed.")
    if Studio.get_session!(session.id).state != "cancelled", do: System.halt(1)

  other ->
    IO.puts("confirm_draft failed: #{inspect(other)}")
    System.halt(1)
end

  nil ->
    IO.puts("Expected a cancel_session Draft on the second turn")
    System.halt(1)
end

{thread, turn3, drafts3} =
  run_turn.(thread, "SMOKE 把 10/14 週三的基礎課改成流動，先幫我排 10/14 單次課 19:00-20:15 基礎 Hatha")

IO.inspect(Enum.map(drafts3, & &1.kind), label: "draft kinds on style turn")

cleanup.()
IO.puts("\nDone — SMOKE rows removed.")
```

Run:

```bash
source .env.dev && mix run priv/scripts/line_real_schedule.exs
```

- [ ] **Final:** `mix precommit` green.

---

## Verification note (plan author)

Applied this plan's code on a throwaway copy of branch HEAD (`git worktree add /tmp/plan-slice-3 HEAD --detach`): after Task 8 test updates, `mix compile --warnings-as-errors` and `mix precommit` — **524 tests passed**.

## Ambiguities resolved

| Topic | Choice |
|-------|--------|
| September copy-month count in tests | September 2026 has **4** Mondays for a Monday slot (not 5). |
| `copy_month` apply return | `{:ok, {nil, created_count}}` — no single ledger row (like `makeup_request`). |
| `add_slot` apply return | `{:ok, {"Ganesha.Studio.Slot", slot.id}}`. |
| Missing cancel reason | `propose/2` returns English tool error telling the model to ask the teacher. |
| Real-model script | Separate `line_real_schedule.exs`; smoke Step 8 optional. |
