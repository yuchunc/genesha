# 課表 Calendar Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `/month` into a calendar-first 課表: a month grid with per-day attendee-count marks, a bulk "copy last month's classes" prompt, a chronological agenda list, and a new page to schedule either a standalone class or a recurring weekly class.

**Architecture:** `Ganesha.Studio.Session` gains a standalone case (nullable `slot_id`, its own `label`/`start_time`/`end_time`) so a class can exist without a recurring `Slot`. `MonthLive` is rewritten to load every session in the month at once (`Studio.sessions_in_month/1`), build a calendar grid and a date-grouped agenda from it, and offer a bulk `Studio.copy_month/1` instead of per-slot manual generation. A new `ScheduleLive` at `/month/new` creates either kind of class.

**Tech Stack:** Phoenix LiveView, Ecto/Postgres, ExUnit + `Phoenix.LiveViewTest`.

**Spec:** `docs/superpowers/specs/2026-09-08-schedule-calendar-design.md`

## Global Constraints

- Traditional Chinese UI copy only, matching existing studio vocabulary (see `docs/superpowers/specs/2026-09-06-ui-design-system.md`). Do not reuse "單堂"/"one-off" for the new standalone-class concept — that term already means a drop-in attendance kind (`Fmt.kind("drop_in")`) elsewhere in the app. Use "單次" / "standalone" instead.
- No modals — every new flow is a full LiveView route (`navigate`/`patch`), matching every existing page (`EnrollLive`, `PublishLive`, `SessionLive`).
- No `<.form for={@form}>`/changeset-form pattern for the two new creation forms — this app's existing creation flows (`Catalog.create_package/1` in `SettingsLive`, `Enrolling.enroll_month/1` in `EnrollLive`) submit raw `phx-submit` params straight into a context function; follow that, not `to_form/2`.
- `mix ecto.gen.migration <name>` for the new migration, not a hand-named file.
- Reuse `Studio.generate_month/2` and `Studio.create_slot/1` as-is; do not change their signatures.
- Run `mix test <file>` per task, not the full suite; run `mix precommit` only once, at the very end.

---

## Task 1: Standalone sessions — migration, schema, changeset

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_standalone_fields_to_sessions.exs`
- Modify: `lib/ganesha/studio/session.ex`
- Test: `test/ganesha/studio_test.exs`

**Interfaces:**
- Produces: `Session.changeset/2` now accepts `slot_id: nil` together with `label`/`start_time`/`end_time`, and rejects any other combination. `Studio.create_session/1` (unchanged signature) is the entry point later tasks use for standalone creation.

- [ ] **Step 1: Generate the migration file**

Run: `mix ecto.gen.migration add_standalone_fields_to_sessions`

- [ ] **Step 2: Write the migration**

```elixir
defmodule Ganesha.Repo.Migrations.AddStandaloneFieldsToSessions do
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      modify :slot_id, references(:slots, on_delete: :restrict),
        null: true,
        from: {references(:slots, on_delete: :restrict), null: false}

      # Populated only for a standalone session (slot_id nil) — see
      # Ganesha.Studio.Session's changeset for the mutual-exclusion rule.
      add :label, :string
      add :start_time, :time
      add :end_time, :time
    end
  end
end
```

Run: `mix ecto.migrate`
Expected: migration runs cleanly.

- [ ] **Step 3: Write the failing changeset tests**

Add to `test/ganesha/studio_test.exs` (new `describe` block, after the existing tests):

```elixir
  describe "standalone sessions" do
    test "creates a session with no slot when label, start_time and end_time are given" do
      assert {:ok, session} =
               Studio.create_session(%{
                 date: ~D[2026-08-10],
                 start_time: ~T[19:00:00],
                 end_time: ~T[20:00:00],
                 label: "期間限定：中秋瑜伽",
                 style: "流動",
                 state: "scheduled"
               })

      assert session.slot_id == nil
      assert session.label == "期間限定：中秋瑜伽"
      assert session.start_time == ~T[19:00:00]
    end

    test "rejects a session with neither a slot nor standalone fields" do
      assert {:error, changeset} =
               Studio.create_session(%{date: ~D[2026-08-10], style: "流動", state: "scheduled"})

      assert "單次的課需要日期、時間與名稱" in errors_on(changeset).label
    end

    test "rejects a session with both a slot and standalone fields" do
      slot = monday_slot()

      assert {:error, changeset} =
               Studio.create_session(%{
                 slot_id: slot.id,
                 date: ~D[2026-08-10],
                 start_time: ~T[19:00:00],
                 end_time: ~T[20:00:00],
                 label: "多餘的名稱",
                 style: "流動",
                 state: "scheduled"
               })

      assert "固定班次的課不需要另外填寫名稱與時間" in errors_on(changeset).slot_id
    end
  end
```

Run: `mix test test/ganesha/studio_test.exs`
Expected: FAIL — `create_session/1` currently requires `slot_id`, so the first test fails and the other two currently pass by accident (unrelated errors). All three must fail/error until Step 4 lands.

- [ ] **Step 4: Update the schema and changeset**

Replace `lib/ganesha/studio/session.ex` with:

```elixir
defmodule Ganesha.Studio.Session do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Studio.Slot

  @states ~w(scheduled cancelled)

  schema "sessions" do
    field :date, :date
    field :style, :string
    field :state, :string, default: "scheduled"
    field :cancel_reason, :string

    # Populated only when slot_id is nil — a standalone class with no
    # recurring template behind it. A recurring session derives its label
    # and time range from its slot instead.
    field :label, :string
    field :start_time, :time
    field :end_time, :time

    belongs_to :slot, Slot

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:slot_id, :date, :style, :state, :cancel_reason, :label, :start_time, :end_time])
    |> validate_required([:date, :style, :state])
    |> validate_inclusion(:state, @states)
    |> validate_origin()
    |> unique_constraint([:slot_id, :date], name: "sessions_slot_id_date_index")
    |> foreign_key_constraint(:slot_id)
  end

  @doc "Cancellation always carries a reason; it is shown to students in the roster."
  def cancellation_changeset(session, reason) do
    session
    |> cast(%{cancel_reason: reason}, [:cancel_reason])
    |> put_change(:state, "cancelled")
    |> validate_required([:cancel_reason])
  end

  # A session is either a dated occurrence of a recurring slot, or a
  # standalone class carrying its own label and time range — never both,
  # never neither.
  defp validate_origin(changeset) do
    slot_id = get_field(changeset, :slot_id)
    standalone_fields = [get_field(changeset, :label), get_field(changeset, :start_time), get_field(changeset, :end_time)]

    cond do
      is_nil(slot_id) and Enum.all?(standalone_fields, &(!is_nil(&1))) ->
        changeset

      !is_nil(slot_id) and Enum.all?(standalone_fields, &is_nil/1) ->
        changeset

      is_nil(slot_id) ->
        add_error(changeset, :label, "單次的課需要日期、時間與名稱")

      true ->
        add_error(changeset, :slot_id, "固定班次的課不需要另外填寫名稱與時間")
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/ganesha/studio_test.exs`
Expected: PASS (all tests, including the pre-existing ones — confirm `unique_constraint`/`foreign_key_constraint` on `slot_id` still work with it nullable).

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations lib/ganesha/studio/session.ex test/ganesha/studio_test.exs
git commit -m "feat: support standalone (slot-less) sessions"
```

---

## Task 2: Fmt helpers for a session's display label/time regardless of origin

**Files:**
- Modify: `lib/ganesha_web/fmt.ex`
- Test: `test/ganesha_web/fmt_test.exs` (create if it does not already exist — check with `ls test/ganesha_web/fmt_test.exs` first; if present, add to it)

**Interfaces:**
- Consumes: a `Session` struct with `:slot` preloaded (either `nil` or a loaded `%Slot{}`).
- Produces: `Fmt.session_label/1`, `Fmt.session_time_range/1` — used by `SessionLive` (Task 5) and `MonthLive` (Task 6).

- [ ] **Step 1: Check for an existing Fmt test file**

Run: `ls test/ganesha_web/fmt_test.exs 2>/dev/null || echo "none"`

- [ ] **Step 2: Write the failing tests**

If the file exists, add this `describe` block inside the existing `defmodule ... do ... end`. If it doesn't exist, create it with:

```elixir
defmodule GaneshaWeb.FmtTest do
  use ExUnit.Case, async: true
  alias GaneshaWeb.Fmt

  describe "session_label/1 and session_time_range/1" do
    test "read from the slot for a recurring session" do
      session = %{
        slot: %{label: "早晨練習｜週一 基礎瑜伽", start_time: ~T[09:30:00], end_time: ~T[10:45:00]},
        label: nil,
        start_time: nil,
        end_time: nil
      }

      assert Fmt.session_label(session) == "早晨練習｜基礎瑜伽"
      assert Fmt.session_time_range(session) == "9:30–10:45"
    end

    test "read from the session itself when standalone" do
      session = %{slot: nil, label: "期間限定：中秋瑜伽", start_time: ~T[19:00:00], end_time: ~T[20:00:00]}

      assert Fmt.session_label(session) == "期間限定：中秋瑜伽"
      assert Fmt.session_time_range(session) == "19:00–20:00"
    end
  end
end
```

Run: `mix test test/ganesha_web/fmt_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `session_label/1`.

- [ ] **Step 3: Add the helpers**

In `lib/ganesha_web/fmt.ex`, add after `time_range/2` (after the function ending at line 58 in the current file):

```elixir
  @doc """
  A session's display label — the slot's label when recurring, its own when
  standalone. Requires `:slot` to be preloaded.
  """
  def session_label(%{slot: %{label: label}}), do: slot_title(label)
  def session_label(%{label: label}), do: slot_title(label)

  @doc """
  A session's time range — the slot's when recurring, its own when
  standalone. Requires `:slot` to be preloaded.
  """
  def session_time_range(%{slot: %{start_time: from, end_time: to}}), do: time_range(from, to)
  def session_time_range(%{start_time: from, end_time: to}), do: time_range(from, to)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/ganesha_web/fmt_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha_web/fmt.ex test/ganesha_web/fmt_test.exs
git commit -m "feat: add Fmt.session_label/1 and session_time_range/1"
```

---

## Task 3: `Studio.sessions_in_month/1` and `Studio.copy_month/1`

**Files:**
- Modify: `lib/ganesha/studio.ex`
- Test: `test/ganesha/studio_test.exs`

**Interfaces:**
- Produces: `Studio.sessions_in_month(%Date{} = month) :: [Session.t()]` (preloaded `:slot`), consumed by `MonthLive` (Task 6). `Studio.copy_month(%Date{} = month) :: {:ok, non_neg_integer()}`, consumed by `MonthLive` (Task 6).

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/studio_test.exs`:

```elixir
  describe "sessions_in_month/1" do
    test "returns recurring and standalone sessions together, slot preloaded" do
      slot = monday_slot()
      {:ok, [recurring | _]} = Studio.generate_month(slot, ~D[2026-08-01])

      {:ok, standalone} =
        Studio.create_session(%{
          date: ~D[2026-08-15],
          start_time: ~T[19:00:00],
          end_time: ~T[20:00:00],
          label: "體驗課",
          style: "流動",
          state: "scheduled"
        })

      sessions = Studio.sessions_in_month(~D[2026-08-01])

      assert Enum.find(sessions, &(&1.id == recurring.id)).slot.id == slot.id
      assert Enum.find(sessions, &(&1.id == standalone.id)).slot == nil
    end

    test "excludes sessions outside the month" do
      slot = monday_slot()
      Studio.generate_month(slot, ~D[2026-08-01])
      Studio.generate_month(slot, ~D[2026-09-01])

      assert Enum.all?(Studio.sessions_in_month(~D[2026-08-01]), &(&1.date.month == 8))
    end
  end

  describe "copy_month/1" do
    test "generates every active slot's sessions and skips inactive ones" do
      active = monday_slot()

      {:ok, inactive} =
        Studio.create_slot(%{
          weekday: 5,
          start_time: ~T[18:00:00],
          end_time: ~T[19:00:00],
          default_style: "流動",
          label: "週五",
          active: false
        })

      assert {:ok, 5} = Studio.copy_month(~D[2026-08-01])
      assert length(Studio.sessions_for_slot_in_month(active, ~D[2026-08-01])) == 5
      assert Studio.sessions_for_slot_in_month(inactive, ~D[2026-08-01]) == []
    end

    test "is idempotent" do
      monday_slot()
      assert {:ok, 5} = Studio.copy_month(~D[2026-08-01])
      assert {:ok, 0} = Studio.copy_month(~D[2026-08-01])
    end
  end
```

Run: `mix test test/ganesha/studio_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `sessions_in_month/1` and `copy_month/1`.

- [ ] **Step 2: Add the functions**

In `lib/ganesha/studio.ex`, add after `sessions_for_slot_in_month/2`:

```elixir
  @doc """
  Every session in `month`, recurring and standalone alike, ordered by date.

  Preloads `:slot` — callers tell a recurring session from a standalone one
  by whether `session.slot` is `nil`.
  """
  def sessions_in_month(%Date{} = month) do
    Repo.all(
      from s in Session,
        where: s.date >= ^Date.beginning_of_month(month) and s.date <= ^Clock.end_of_month(month),
        order_by: [asc: s.date, asc: s.id],
        preload: [:slot]
    )
  end

  @doc """
  Runs `generate_month/2` for every active slot, in one transaction.

  Backs the "copy last month's classes" prompt: idempotent, so it never
  duplicates or overwrites a cancellation or style override already made
  this month. Returns the number of sessions newly created (not the
  month's total).
  """
  def copy_month(%Date{} = month) do
    Repo.transaction(fn ->
      Enum.reduce(list_active_slots(), 0, fn slot, created ->
        before_count = slot |> sessions_for_slot_in_month(month) |> length()
        {:ok, sessions} = generate_month(slot, month)
        created + (length(sessions) - before_count)
      end)
    end)
  end
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `mix test test/ganesha/studio_test.exs`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/ganesha/studio.ex test/ganesha/studio_test.exs
git commit -m "feat: add Studio.sessions_in_month/1 and copy_month/1"
```

---

## Task 4: `Roster.count_by_session/1`

**Files:**
- Modify: `lib/ganesha/roster.ex`
- Test: `test/ganesha/roster_test.exs`

**Interfaces:**
- Produces: `Roster.count_by_session([integer()]) :: %{integer() => non_neg_integer()}`, consumed by `MonthLive` (Task 6).

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/roster_test.exs`:

```elixir
  describe "count_by_session/1" do
    test "counts attendance rows per session, including no-shows" do
      {monday, [session | _]} = slot_with_sessions(1, "週一")
      {:ok, student_a} = People.create_student(%{display_name: "小美"})
      {:ok, student_b} = People.create_student(%{display_name: "小華"})
      {:ok, monthly} = package("monthly", 400)

      {:ok, purchase_a} =
        Sales.create_purchase(%{
          student_id: student_a.id,
          package_id: monthly.id,
          slot_id: monday.id,
          list_price: 2000
        })

      {:ok, purchase_b} =
        Sales.create_purchase(%{
          student_id: student_b.id,
          package_id: monthly.id,
          slot_id: monday.id,
          list_price: 2000
        })

      {:ok, _} = Roster.enroll(session, student_a, purchase_a)
      {:ok, attendance_b} = Roster.enroll(session, student_b, purchase_b)
      {:ok, _} = Roster.mark_no_show(attendance_b)

      assert Roster.count_by_session([session.id]) == %{session.id => 2}
    end

    test "returns an empty map for an empty list without querying" do
      assert Roster.count_by_session([]) == %{}
    end
  end
```

Run: `mix test test/ganesha/roster_test.exs`
Expected: FAIL with `UndefinedFunctionError`.

- [ ] **Step 2: Add the function**

In `lib/ganesha/roster.ex`, add after `list_for_session/1`:

```elixir
  @doc """
  Attendee counts for a batch of sessions, keyed by session id.

  Counts every attendance row regardless of state — a no-show still held a
  seat. Backs the calendar's per-class attendee mark without one query per
  session.
  """
  def count_by_session([]), do: %{}

  def count_by_session(session_ids) do
    Attendance
    |> where([a], a.session_id in ^session_ids)
    |> group_by([a], a.session_id)
    |> select([a], {a.session_id, count(a.id)})
    |> Repo.all()
    |> Map.new()
  end
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `mix test test/ganesha/roster_test.exs`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/ganesha/roster.ex test/ganesha/roster_test.exs
git commit -m "feat: add Roster.count_by_session/1"
```

---

## Task 5: `SessionLive` renders a standalone session

**Files:**
- Modify: `lib/ganesha_web/live/session_live.ex:142-167`
- Test: `test/ganesha_web/live/session_live_test.exs`

**Interfaces:**
- Consumes: `Fmt.session_label/1`, `Fmt.session_time_range/1` (Task 2).

- [ ] **Step 1: Write the failing test**

Add to `test/ganesha_web/live/session_live_test.exs`:

```elixir
  test "shows a standalone session with no slot", %{conn: conn} do
    {:ok, session} =
      Studio.create_session(%{
        date: ~D[2026-08-20],
        start_time: ~T[19:00:00],
        end_time: ~T[20:30:00],
        label: "期間限定：滿月瑜伽",
        style: "流動",
        state: "scheduled"
      })

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

    assert html =~ "滿月瑜伽"
    assert html =~ "19:00–20:30"
  end
```

Run: `mix test test/ganesha_web/live/session_live_test.exs`
Expected: FAIL — `@session.slot.weekday` raises `KeyError`/`ArgumentError` on a `nil` slot (current code at line 147/156).

- [ ] **Step 2: Fix the style-override calculation and the subtitle markup**

In `lib/ganesha_web/live/session_live.ex`, replace the `render/1` head (currently lines 142-148):

```elixir
  def render(assigns) do
    assigns = assign(assigns, cancelled: assigns.session.state == "cancelled", style_override: style_override?(assigns.session))

    ~H"""
```

and replace the subtitle block (currently lines 153-167):

```elixir
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.seal
              weekday={@session.date}
              size="sm"
              tone={if @cancelled, do: "sindoor", else: "ink"}
            />
            <span class="font-display text-ink">{Fmt.session_label(@session)}</span>
            <span class="font-display">{Fmt.session_time_range(@session)}</span>
            <.pill :if={@style_override} tone="turmeric">{@session.style}</.pill>
            <span :if={@session.style && !@style_override}>{@session.style}</span>
          </span>
        </:subtitle>
```

and add this private helper near `row_rule/1` at the bottom of the module:

```elixir
  defp style_override?(%{slot: %{default_style: default}} = session), do: session.style != default
  defp style_override?(_session), do: false
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `mix test test/ganesha_web/live/session_live_test.exs`
Expected: PASS (all tests, including the pre-existing recurring-session ones — confirms `@session.date`-based seal and `Fmt.session_label/session_time_range` produce identical output to the old slot-based markup for a recurring session).

- [ ] **Step 4: Commit**

```bash
git add lib/ganesha_web/live/session_live.ex test/ganesha_web/live/session_live_test.exs
git commit -m "feat: render standalone sessions on the session detail page"
```

---

## Task 6: `MonthLive` — calendar, agenda, copy prompt, roster strip

**Files:**
- Modify: `lib/ganesha_web/live/month_live.ex` (full rewrite)
- Modify: `assets/css/app.css:237-245`
- Modify: `test/ganesha_web/live/month_live_test.exs` (full rewrite)

**Interfaces:**
- Consumes: `Studio.sessions_in_month/1`, `Studio.copy_month/1` (Task 3), `Roster.count_by_session/1` (Task 4), `Fmt.session_label/1`, `Fmt.session_time_range/1` (Task 2).
- Produces: nothing new consumed by later tasks except the route `~p"/month/new?year=#{...}&month=#{...}"` link target that Task 7 must exist at.

This task replaces the per-slot manual "generate" UI entirely — a recurring class's sessions now come from `copy_month/1` (this task) or from being generated immediately on creation (Task 7). There is no remaining caller of a per-slot "generate" button, so the old `handle_event("generate", ...)` clause and its section/button in the template are deleted, not kept alongside the new UI.

- [ ] **Step 1: Replace `test/ganesha_web/live/month_live_test.exs` entirely**

```elixir
defmodule GaneshaWeb.MonthLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp monday_slot do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    slot
  end

  test "calendar shows a mark with the attendee count on the session's date", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "蘭子"})
    {:ok, pkg} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    assert has_element?(view, "#cal-2026-08-03", "1")
    assert has_element?(view, "#date-2026-08-03")
    assert has_element?(view, "#session-#{session.id}")
  end

  test "shows the copy-previous-month prompt only when this month is empty and last month had classes",
       %{conn: conn} do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/9")
    assert has_element?(view, "#copy-prompt")

    view |> element("#copy-previous-month") |> render_click()

    refute has_element?(view, "#copy-prompt")
    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-09-01])) > 0
  end

  test "dismissing the copy prompt hides it without copying anything", %{conn: conn} do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/9")

    view |> element("#dismiss-copy-prompt") |> render_click()

    refute has_element?(view, "#copy-prompt")
    assert Studio.sessions_for_slot_in_month(slot, ~D[2026-09-01]) == []
  end

  test "does not show the copy prompt once this month already has a recurring session", %{conn: conn} do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, _} = Studio.generate_month(slot, ~D[2026-09-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/9")

    refute has_element?(view, "#copy-prompt")
  end

  test "overrides the style for a single session", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    view
    |> form("#style-form-#{session.id}", %{"style" => "流動"})
    |> render_submit()

    assert Studio.get_session!(session.id).style == "流動"
  end

  test "cancelling a session issues portable credits to the enrolled students", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "蘭子"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    view
    |> form("#cancel-form-#{session.id}", %{"reason" => "颱風假"})
    |> render_submit()

    assert Studio.get_session!(session.id).state == "cancelled"

    assert [credit] = Roster.available_credits(student.id, ~D[2026-12-01])
    assert credit.source == "cancellation"
    assert is_nil(credit.expires_on)
  end

  test "cancelling without a reason shows an error and changes nothing", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    html =
      view
      |> form("#cancel-form-#{session.id}", %{"reason" => ""})
      |> render_submit()

    assert html =~ "請填寫停課原因"
    assert Studio.get_session!(session.id).state == "scheduled"
  end

  test "agenda groups two sessions on the same date under one heading", %{conn: conn} do
    monday = monday_slot()

    {:ok, evening} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "流動",
        label: "晚間練習｜週一 流動瑜伽"
      })

    {:ok, [morning_session | _]} = Studio.generate_month(monday, ~D[2026-08-01])
    {:ok, [evening_session | _]} = Studio.generate_month(evening, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    assert has_element?(view, "#date-2026-08-03 #session-#{morning_session.id}")
    assert has_element?(view, "#date-2026-08-03 #session-#{evening_session.id}")
  end

  test "the roster shortcut links to the enroll flow for an active slot with sessions", %{conn: conn} do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    assert has_element?(view, "#enroll-slot-#{slot.id}")
  end
end
```

Run: `mix test test/ganesha_web/live/month_live_test.exs`
Expected: FAIL — none of the new ids/behavior exist yet in the current template.

- [ ] **Step 2: Replace `lib/ganesha_web/live/month_live.ex` entirely**

```elixir
defmodule GaneshaWeb.MonthLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Repo, Roster, Studio}
  alias GaneshaWeb.Fmt

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_month(params) |> load_month()}
  end

  defp assign_month(socket, %{"year" => year, "month" => month}) do
    with {y, ""} <- Integer.parse(year),
         {m, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(y, m, 1) do
      assign(socket, :month, date)
    else
      _ -> assign_month(socket, %{})
    end
  end

  defp assign_month(socket, _params) do
    assign(socket, :month, Date.beginning_of_month(Clock.today()))
  end

  defp load_month(socket) do
    month = socket.assigns.month
    sessions = Studio.sessions_in_month(month)
    counts = Roster.count_by_session(Enum.map(sessions, & &1.id))
    active_slots = Studio.list_active_slots()
    recurring_this_month? = Enum.any?(sessions, & &1.slot_id)

    previous_had_recurring? =
      month |> prev_month() |> Studio.sessions_in_month() |> Enum.any?(& &1.slot_id)

    socket
    |> assign(:calendar_cells, calendar_cells(month, sessions, counts))
    |> assign(:agenda_dates, agenda_dates(sessions, counts))
    |> assign(:roster_slots, roster_slots(active_slots, sessions))
    |> assign(
      :show_copy_prompt,
      active_slots != [] and not recurring_this_month? and previous_had_recurring?
    )
  end

  # One entry per day of the month, `nil` for the blank cells before the 1st
  # so the grid's columns line up with the weekday header.
  defp calendar_cells(%Date{} = month, sessions, counts) do
    by_date = Enum.group_by(sessions, & &1.date)
    first = Date.beginning_of_month(month)
    leading = Date.day_of_week(first) - 1

    days =
      Enum.map(Date.range(first, Clock.end_of_month(month)), fn date ->
        %{
          date: date,
          marks:
            by_date
            |> Map.get(date, [])
            |> Enum.map(fn session ->
              %{cancelled?: session.state == "cancelled", count: Map.get(counts, session.id, 0)}
            end)
        }
      end)

    List.duplicate(nil, leading) ++ days
  end

  # One entry per date that has a session, chronological, each carrying
  # every session on that date in time order — a date with two overlapping
  # classes renders two rows under one heading.
  defp agenda_dates(sessions, counts) do
    sessions
    |> Enum.group_by(& &1.date)
    |> Enum.sort_by(fn {date, _sessions} -> date end, Date)
    |> Enum.map(fn {date, day_sessions} ->
      %{
        date: date,
        entries:
          day_sessions
          |> Enum.sort_by(&session_start_time/1, Time)
          |> Enum.map(&%{session: &1, count: Map.get(counts, &1.id, 0)})
      }
    end)
  end

  defp session_start_time(%{slot: %{start_time: time}}), do: time
  defp session_start_time(session), do: session.start_time

  # Active slots with at least one session this month — the "本月名單" strip
  # links to the slot+month enrollment flow, which only makes sense once
  # there is something to enroll into.
  defp roster_slots(active_slots, sessions) do
    slot_ids_with_sessions = sessions |> Enum.filter(& &1.slot_id) |> MapSet.new(& &1.slot_id)
    Enum.filter(active_slots, &MapSet.member?(slot_ids_with_sessions, &1.id))
  end

  defp style_override?(%{slot: %{default_style: default}} = session), do: session.style != default
  defp style_override?(_session), do: false

  @impl true
  def handle_event("copy_previous_month", _params, socket) do
    {:ok, created} = Studio.copy_month(socket.assigns.month)

    {:noreply,
     socket
     |> put_flash(:info, "已複製 #{created} 堂課")
     |> load_month()}
  end

  def handle_event("dismiss_copy_prompt", _params, socket) do
    {:noreply, assign(socket, :show_copy_prompt, false)}
  end

  def handle_event("set_style", %{"session-id" => id, "style" => style}, socket) do
    {:ok, _session} = id |> Studio.get_session!() |> Studio.set_style(style)

    {:noreply, socket |> put_flash(:info, "已更新課型") |> load_month()}
  end

  def handle_event("cancel", %{"session-id" => id, "reason" => reason}, socket) do
    session = Studio.get_session!(id)

    # Credits are issued here rather than inside Studio so both steps are
    # visible at the call site; wrapped in one transaction so a session is
    # never left cancelled without its students' makeup credits, or the
    # reverse — the render guard hides the cancel form once state flips, so
    # there is no UI path to retry a partial failure.
    result =
      Repo.transaction(fn ->
        case Studio.cancel_session(session, reason) do
          {:ok, cancelled} ->
            {:ok, credits} = Roster.issue_cancellation_credits(cancelled)
            credits

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, credits} ->
        {:noreply,
         socket
         |> put_flash(:info, "已停課，發出 #{length(credits)} 張補課額度")
         |> load_month()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請填寫停課原因")}
    end
  end

  # The month either side of the one on screen, for the header's navigation
  # and the copy-prompt check.
  defp prev_month(%Date{} = month), do: month |> Date.beginning_of_month() |> Date.add(-1)
  defp next_month(%Date{} = month), do: month |> Date.end_of_month() |> Date.add(1)

  defp month_path(%Date{} = month), do: ~p"/month/#{month.year}/#{month.month}"

  # The left rule carries the date's state.
  defp session_rule(%{state: "cancelled"}), do: "border-sindoor"
  defp session_rule(_session), do: "border-rule"

  # A disclosure control that reads as quiet text, with the native marker gone
  # and a 44px tap target kept.
  defp summary_class do
    "flex min-h-11 w-fit cursor-pointer list-none items-center text-sm text-ink-faint transition-colors hover:text-ink [&::-webkit-details-marker]:hidden"
  end

  attr :cell, :any, required: true

  defp calendar_cell(%{cell: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  defp calendar_cell(assigns) do
    ~H"""
    <a
      href={"#date-#{@cell.date}"}
      id={"cal-#{@cell.date}"}
      class="flex aspect-square flex-col items-center justify-center gap-0.5 bg-paper-raised text-sm"
    >
      <span class="font-display tabular-nums">{@cell.date.day}</span>
      <span :if={@cell.marks != []} class="flex gap-0.5">
        <span
          :for={mark <- @cell.marks}
          class={[
            "flex h-3.5 min-w-3.5 items-center justify-center border px-0.5 text-[9px] tabular-nums",
            mark.cancelled? && "border-sindoor text-sindoor-ink",
            !mark.cancelled? && "border-turmeric-ink text-turmeric-ink"
          ]}
        >
          {mark.count}
        </span>
      </span>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:month}>
      <.page_header title={Fmt.month_title(@month)}>
        <:actions>
          <.button variant="quiet" navigate={month_path(prev_month(@month))} aria-label="上個月">
            <.icon name="hero-chevron-left" class="size-5" />
          </.button>
          <.button variant="quiet" navigate={month_path(next_month(@month))} aria-label="下個月">
            <.icon name="hero-chevron-right" class="size-5" />
          </.button>
          <.button variant="quiet" navigate={~p"/publish"}>發布課表</.button>
        </:actions>
      </.page_header>

      <div class="mt-2">
        <.button variant="primary" navigate={~p"/month/new?year=#{@month.year}&month=#{@month.month}"}>
          排課
        </.button>
      </div>

      <div
        :if={@show_copy_prompt}
        id="copy-prompt"
        class="mt-6 flex items-center justify-between gap-3 border-l-[3px] border-rule py-3 pl-4"
      >
        <p class="text-sm text-ink-soft">
          要複製 {Fmt.month_title(prev_month(@month))} 的課表嗎？
        </p>
        <div class="flex shrink-0 items-center gap-2">
          <.button id="copy-previous-month" variant="primary" phx-click="copy_previous_month">
            複製
          </.button>
          <.button
            id="dismiss-copy-prompt"
            variant="quiet"
            phx-click="dismiss_copy_prompt"
            aria-label="不用了"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.button>
        </div>
      </div>

      <div class="mt-6 border border-rule p-3">
        <div class="grid grid-cols-7 gap-px pb-2 text-center text-xs text-ink-faint">
          <span :for={weekday <- 1..7}>{Fmt.weekday_glyph(weekday)}</span>
        </div>
        <div class="grid grid-cols-7 gap-px">
          <.calendar_cell :for={cell <- @calendar_cells} cell={cell} />
        </div>
      </div>

      <div :if={@roster_slots != []} class="mt-6 space-y-1">
        <.link
          :for={slot <- @roster_slots}
          id={"enroll-slot-#{slot.id}"}
          navigate={~p"/enroll/#{slot.id}/#{@month.year}/#{@month.month}"}
          class="flex min-h-11 items-center gap-2 text-ink transition-colors hover:text-turmeric-ink"
        >
          <.seal weekday={slot.weekday} size="sm" />
          <span class="font-display">{Fmt.slot_title(slot.label)}</span>
          <span class="ml-auto text-sm text-ink-soft">本月名單</span>
        </.link>
      </div>

      <.empty :if={@agenda_dates == []} id="no-sessions" class="mt-8">
        本月還沒有課程。用上面的「排課」建立第一堂課。
      </.empty>

      <div :if={@agenda_dates != []} id="agenda" class="slides-in mt-8 space-y-6">
        <div :for={day <- @agenda_dates} id={"date-#{day.date}"} data-date={day.date}>
          <h2 class="font-display text-lg text-ink">{Fmt.date_with_weekday(day.date)}</h2>

          <ul class="mt-2 space-y-2">
            <li
              :for={entry <- day.entries}
              id={"session-#{entry.session.id}"}
              class={["border-l-[3px] pl-4", session_rule(entry.session)]}
            >
              <.link
                navigate={~p"/sessions/#{entry.session.id}"}
                class="flex min-h-11 items-center gap-2 text-ink transition-colors hover:text-turmeric-ink"
              >
                <span class="font-display tabular-nums">{Fmt.session_time_range(entry.session)}</span>
                <span class="text-ink-soft">{Fmt.session_label(entry.session)}</span>
                <.pill :if={style_override?(entry.session)} tone="turmeric">
                  {entry.session.style}
                </.pill>
                <.pill :if={entry.session.state == "cancelled"} tone="sindoor">已取消</.pill>
                <span class="ml-auto shrink-0 text-sm text-ink-soft">{entry.count} 人</span>
              </.link>

              <p
                :if={entry.session.state == "cancelled" and entry.session.cancel_reason}
                class="pb-2 text-xs text-sindoor-ink"
              >
                {entry.session.cancel_reason}
              </p>

              <details :if={entry.session.state == "scheduled"} class="pb-1">
                <summary class={summary_class()}>調整</summary>

                <div class="mt-1 space-y-4 pb-3">
                  <form
                    id={"style-form-#{entry.session.id}"}
                    phx-submit="set_style"
                    class="flex items-end gap-2"
                  >
                    <input type="hidden" name="session-id" value={entry.session.id} />
                    <div class="flex-1">
                      <.input
                        type="text"
                        name="style"
                        value={entry.session.style}
                        label="課型"
                        required
                      />
                    </div>
                    <.button variant="primary">更新課型</.button>
                  </form>

                  <form
                    id={"cancel-form-#{entry.session.id}"}
                    phx-submit="cancel"
                    class="flex items-end gap-2"
                  >
                    <input type="hidden" name="session-id" value={entry.session.id} />
                    <div class="flex-1">
                      <.input
                        type="text"
                        name="reason"
                        value=""
                        label="停課原因"
                        placeholder="例如：颱風假"
                      />
                    </div>
                    <.button variant="danger">停課</.button>
                  </form>
                </div>
              </details>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 3: Add the `.slides-in` animation**

Replace `assets/css/app.css:239-245` (the `prefers-reduced-motion` block) and insert a new block before it:

```css
/* The agenda list under the calendar replays this each time the month
   changes — prev/next fully remount the page, so a plain CSS animation on
   the container plays automatically without any JS hook. */
.slides-in {
  animation: slide-in 240ms cubic-bezier(0.22, 1, 0.36, 1) both;
}

@keyframes slide-in {
  from {
    opacity: 0;
    transform: translateX(8px);
  }
  to {
    opacity: 1;
    transform: translateX(0);
  }
}

@media (prefers-reduced-motion: reduce) {
  .struck::after,
  .fills-across,
  .fills-up,
  .slides-in {
    animation: none;
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/ganesha_web/live/month_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha_web/live/month_live.ex assets/css/app.css test/ganesha_web/live/month_live_test.exs
git commit -m "feat: rebuild 課表 as a calendar with an agenda list and copy-month prompt"
```

---

## Task 7: Schedule-creation flow (`ScheduleLive`)

**Files:**
- Create: `lib/ganesha_web/live/schedule_live.ex`
- Modify: `lib/ganesha_web/router.ex`
- Create: `test/ganesha_web/live/schedule_live_test.exs`

**Interfaces:**
- Consumes: `Studio.create_session/1` (Task 1), `Studio.create_slot/1`, `Studio.generate_month/2` (both pre-existing, unchanged), `Fmt.weekday/1` (pre-existing).
- Produces: the route `/month/new` that `MonthLive`'s "排課" button (Task 6) already links to.

- [ ] **Step 1: Add the route**

In `lib/ganesha_web/router.ex`, inside the `live_session :require_authenticated_user` block, add directly after `live "/month/:year/:month", MonthLive, :index`:

```elixir
      live "/month/new", ScheduleLive, :new
```

- [ ] **Step 2: Write the failing tests**

Create `test/ganesha_web/live/schedule_live_test.exs`:

```elixir
defmodule GaneshaWeb.ScheduleLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.Studio

  setup :register_and_log_in_user

  test "creates a standalone session and returns to its month", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8")

    {:ok, _view, _html} =
      view
      |> form("#standalone-form", %{
        "session" => %{
          "date" => "2026-08-20",
          "start_time" => "19:00",
          "end_time" => "20:00",
          "label" => "期間限定：中秋瑜伽",
          "style" => "流動"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/month/2026/8")

    assert [session] = Studio.sessions_in_month(~D[2026-08-01])
    assert session.slot_id == nil
    assert session.label == "期間限定：中秋瑜伽"
    assert session.start_time == ~T[19:00:00]
  end

  test "creates a recurring class and generates it for the viewed month", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8&mode=recurring")

    {:ok, _view, _html} =
      view
      |> form("#recurring-form", %{
        "slot" => %{
          "weekday" => "1",
          "start_time" => "09:30",
          "end_time" => "10:45",
          "label" => "早晨練習｜週一 基礎瑜伽",
          "default_style" => "基礎"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/month/2026/8")

    assert [slot] = Studio.list_active_slots()
    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01])) == 5
  end

  test "switches between the standalone and recurring forms", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8")

    assert has_element?(view, "#standalone-form")
    refute has_element?(view, "#recurring-form")

    view |> element("#mode-recurring") |> render_click()
    assert_patch(view, ~p"/month/new?year=2026&month=8&mode=recurring")

    assert has_element?(view, "#recurring-form")
    refute has_element?(view, "#standalone-form")
  end
end
```

Run: `mix test test/ganesha_web/live/schedule_live_test.exs`
Expected: FAIL — `GaneshaWeb.ScheduleLive` does not exist, route does not resolve.

- [ ] **Step 3: Write `ScheduleLive`**

Create `lib/ganesha_web/live/schedule_live.ex`:

```elixir
defmodule GaneshaWeb.ScheduleLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Studio}
  alias GaneshaWeb.Fmt

  @modes ~w(standalone recurring)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    mode = if params["mode"] in @modes, do: params["mode"], else: "standalone"

    {:noreply, socket |> assign_month(params) |> assign(:mode, mode)}
  end

  defp assign_month(socket, %{"year" => year, "month" => month}) do
    with {y, ""} <- Integer.parse(year),
         {m, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(y, m, 1) do
      assign(socket, :month, date)
    else
      _ -> assign_month(socket, %{})
    end
  end

  defp assign_month(socket, _params) do
    assign(socket, :month, Date.beginning_of_month(Clock.today()))
  end

  @impl true
  def handle_event("create_standalone", %{"session" => params}, socket) do
    attrs =
      params
      |> Map.put("state", "scheduled")
      |> normalize_times(["start_time", "end_time"])

    case Studio.create_session(attrs) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/month/#{session.date.year}/#{session.date.month}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請確認日期、時間與名稱都已填寫")}
    end
  end

  def handle_event("create_recurring", %{"slot" => params}, socket) do
    attrs = normalize_times(params, ["start_time", "end_time"])

    case Studio.create_slot(attrs) do
      {:ok, slot} ->
        {:ok, _sessions} = Studio.generate_month(slot, socket.assigns.month)
        month = socket.assigns.month
        {:noreply, push_navigate(socket, to: ~p"/month/#{month.year}/#{month.month}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請確認星期、時間與名稱都已填寫")}
    end
  end

  # A native <input type="time"> submits "HH:MM" without seconds; Ecto's
  # :time cast wants "HH:MM:SS".
  defp normalize_times(params, keys) do
    Enum.reduce(keys, params, fn key, acc -> Map.update(acc, key, nil, &normalize_time/1) end)
  end

  defp normalize_time(hm) when is_binary(hm) and byte_size(hm) == 5, do: hm <> ":00"
  defp normalize_time(other), do: other

  defp weekday_options, do: Enum.map(1..7, &{Fmt.weekday(&1), &1})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:month}
      back={~p"/month/#{@month.year}/#{@month.month}"}
    >
      <.page_header title="排課">
        <:subtitle>{Fmt.month_title(@month)}</:subtitle>
      </.page_header>

      <nav
        id="schedule-mode"
        aria-label="排課方式"
        class="mb-8 flex divide-x divide-rule border border-rule"
      >
        <.link
          :for={{key, label} <- [{"standalone", "單次"}, {"recurring", "固定班次"}]}
          id={"mode-#{key}"}
          patch={~p"/month/new?year=#{@month.year}&month=#{@month.month}&mode=#{key}"}
          aria-current={@mode == key && "page"}
          class={[
            "flex min-h-11 flex-1 items-center justify-center px-2 py-2 font-display text-base",
            @mode == key && "bg-ink text-paper",
            @mode != key && "text-ink-soft hover:bg-sunk"
          ]}
        >
          {label}
        </.link>
      </nav>

      <form
        :if={@mode == "standalone"}
        id="standalone-form"
        phx-submit="create_standalone"
        class="space-y-3"
      >
        <.input type="date" name="session[date]" value="" label="日期" required />
        <.input type="time" name="session[start_time]" value="" label="開始時間" required />
        <.input type="time" name="session[end_time]" value="" label="結束時間" required />
        <.input type="text" name="session[label]" value="" label="課程名稱" required />
        <.input type="text" name="session[style]" value="" label="課型" required />
        <.button variant="primary">排這堂課</.button>
      </form>

      <form
        :if={@mode == "recurring"}
        id="recurring-form"
        phx-submit="create_recurring"
        class="space-y-3"
      >
        <.input
          type="select"
          name="slot[weekday]"
          options={weekday_options()}
          value=""
          prompt="請選擇星期"
          label="星期"
          required
        />
        <.input type="time" name="slot[start_time]" value="" label="開始時間" required />
        <.input type="time" name="slot[end_time]" value="" label="結束時間" required />
        <.input type="text" name="slot[label]" value="" label="課程名稱" required />
        <.input type="text" name="slot[default_style]" value="" label="課型" required />
        <input type="hidden" name="slot[active]" value="true" />
        <.button variant="primary">建立固定班次</.button>
      </form>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/ganesha_web/live/schedule_live_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha_web/live/schedule_live.ex lib/ganesha_web/router.ex test/ganesha_web/live/schedule_live_test.exs
git commit -m "feat: add /month/new to schedule a standalone or recurring class"
```

---

## Task 8: Bottom-nav label

**Files:**
- Modify: `lib/ganesha_web/components/layouts.ex:211`

- [ ] **Step 1: Change the label**

In `lib/ganesha_web/components/layouts.ex`, change:

```elixir
        label="月課表"
```

(inside the `:month` `<.nav_item>`) to:

```elixir
        label="課表"
```

- [ ] **Step 2: Smoke-check the whole suite touching `/month`**

Run: `mix test test/ganesha_web/live/month_live_test.exs test/ganesha_web/live/schedule_live_test.exs test/ganesha_web/live/session_live_test.exs test/ganesha_web/live/dashboard_live_test.exs`
Expected: PASS — no test asserts the old "月課表" text.

- [ ] **Step 3: Commit**

```bash
git add lib/ganesha_web/components/layouts.ex
git commit -m "chore: rename bottom-nav label 月課表 to 課表"
```

---

## Task 9: `Studio.next_session/0` and the Dashboard day-variant see standalone sessions

Discovered during Task 1's review: `Studio.next_session/0` inner-joins `:slot`, so once `slot_id` can be `nil` (Task 1), a standalone session can never be returned as "next" even when it is the soonest scheduled class — it is silently excluded, and the dashboard shows a later recurring session instead. `DashboardLive`'s day-variant and its `style_overridden?/1` helper also read `@session.slot.weekday`/`label`/`start_time`/`end_time`/`default_style` directly and would crash the moment a standalone session ever reaches them. This was missed during brainstorming (the spec scoped consumer updates to "enroll flow, session detail, cancellation" and did not audit the Dashboard). Not load-bearing for any other task in this plan — independent, can run any time after Task 1.

**Files:**
- Modify: `lib/ganesha/studio.ex` (`next_session/0`)
- Modify: `lib/ganesha_web/live/dashboard_live.ex`
- Test: `test/ganesha/studio_test.exs`
- Test: `test/ganesha_web/live/dashboard_live_test.exs`

**Interfaces:**
- Consumes: nothing from other tasks (only Task 1's nullable `slot_id`).

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/studio_test.exs`, inside the existing `next_session/0` tests area (after "next_session/0 skips cancelled sessions"):

```elixir
  test "next_session/0 includes a standalone session and orders it against slot sessions" do
    slot = monday_slot()
    today = Ganesha.Clock.today()

    {:ok, _later} =
      Studio.create_session(%{slot_id: slot.id, date: Date.add(today, 7), style: "基礎"})

    {:ok, standalone} =
      Studio.create_session(%{
        date: today,
        start_time: ~T[07:00:00],
        end_time: ~T[08:00:00],
        label: "體驗課",
        style: "流動",
        state: "scheduled"
      })

    next = Studio.next_session()
    assert next.id == standalone.id
    assert next.slot == nil
  end
```

Add to `test/ganesha_web/live/dashboard_live_test.exs`, after `session_today/0`:

```elixir
  test "the day variant renders a standalone next session", %{conn: conn} do
    today = Clock.today()

    {:ok, _session} =
      Studio.create_session(%{
        date: today,
        start_time: ~T[07:00:00],
        end_time: ~T[08:00:00],
        label: "體驗課",
        style: "流動",
        state: "scheduled"
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#dash-next-session")
    assert render(view) =~ "體驗課"
  end
```

Run: `mix test test/ganesha/studio_test.exs test/ganesha_web/live/dashboard_live_test.exs`
Expected: FAIL — the new `studio_test.exs` case gets `nil` back from `next_session/0` (inner join excludes the standalone session); the new `dashboard_live_test.exs` case raises on `@session.slot.weekday` (`KeyError`/`ArgumentError` on `nil`).

- [ ] **Step 2: Fix `Studio.next_session/0`**

In `lib/ganesha/studio.ex`, replace the `next_session/0` function:

```elixir
  @doc "The next scheduled session today or later, in Taipei terms."
  def next_session do
    today = Clock.today()

    Repo.one(
      from s in Session,
        left_join: slot in assoc(s, :slot),
        where: s.date >= ^today and s.state == "scheduled",
        order_by: [asc: s.date, asc: fragment("coalesce(?, ?)", slot.start_time, s.start_time)],
        limit: 1,
        preload: [slot: slot]
    )
  end
```

- [ ] **Step 3: Fix `DashboardLive`'s day-variant and `style_overridden?/1`**

In `lib/ganesha_web/live/dashboard_live.ex`, replace the seal/label/time-range lines inside `day/1` (currently the three lines using `@session.slot.weekday`, `@session.slot.label`, `@session.slot.start_time`/`end_time`):

```elixir
        <.seal weekday={@session.date} size="lg" filled />
        <div class="min-w-0">
          <p class="font-display text-lg leading-snug text-ink">
            {Fmt.session_label(@session)}
          </p>
          <p class="font-display text-base text-ink-soft">
            {Fmt.session_time_range(@session)}
          </p>
```

Replace `style_overridden?/1`:

```elixir
  defp style_overridden?(%{slot: %{default_style: default}} = session), do: session.style != default
  defp style_overridden?(_session), do: false
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/ganesha/studio_test.exs test/ganesha_web/live/dashboard_live_test.exs`
Expected: PASS (including the pre-existing `next_session/0` tie-break/cancelled tests and the pre-existing dashboard day-variant test — confirms the `left_join` + `coalesce` ordering and `Fmt.session_label`/`session_time_range` produce identical results to the old slot-only code for a recurring session).

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/studio.ex lib/ganesha_web/live/dashboard_live.ex test/ganesha/studio_test.exs test/ganesha_web/live/dashboard_live_test.exs
git commit -m "fix: include standalone sessions in next_session/0 and the dashboard day view"
```

---

## Final Verification

- [ ] Run `mix precommit` and fix anything it flags.
- [ ] Manually smoke-test in the browser: visit `/month`, confirm the calendar renders with marks, schedule a standalone class via "排課", schedule a recurring class, navigate to an empty future month and confirm the copy prompt appears and works, confirm the agenda list groups by date.
