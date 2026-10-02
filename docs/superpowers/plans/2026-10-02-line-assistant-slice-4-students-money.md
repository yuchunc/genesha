# LINE Teacher Assistant — Slice 4 (Students and Money) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the six change tasks for students and money (spec §3.1 #12, #15–20) to the Teacher chat so enrollment, payment confirmation, price overrides, attendance/no-shows, makeup bookings, new students, and package edits all flow through Drafts with the same domain checks as the web UI.

**Architecture:** One `Ganesha.Assistant.Tasks.*` module per task implements `propose/2` (resolve ids, mirror LiveView guards, capture before-values in `parsed`), `apply/2` (re-check then call `Enrolling`, `Sales`, `Roster`, `People`, or `Catalog`), and `describe/2` (display only from `parsed`). `Ganesha.Assistant.Tasks` registers all seven modules on `@teacher` only. A few non-raising getters (`get_slot/1`, `get_payment/1`, `get_purchase/1`, `get_attendance/1`, `get_credit/1`) let tasks turn bad ids into tool errors without raising.

**Tech Stack:** Elixir 1.20, Phoenix 1.8.13, Ecto + `ecto_sqlite3`, existing domain modules — no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md` — slice 4 of §9 ("Students and money"). Builds on slice 1 (`Task` behaviour, Draft lifecycle, `BookOneOff` / `RecordPayment` patterns). Slices 2–3 may land first; registry and `tasks_test.exs` edits below are **additions** anchored on existing modules, never full-file replacements.

## Global Constraints

Carry forward every constraint from `docs/superpowers/plans/2026-10-02-line-assistant-slice-1-foundation.md` §Global Constraints. Additionally for this slice:

- Mirror the web UI checks read from `enroll_live.ex`, `session_live.ex`, `student_live/show.ex`, `settings_live.ex`, and `money_live/cycle.ex` (package availability, scheduled sessions, claimed-only payment confirm, purchase `custom_amount` stale check, attendance state, credit availability on session date, duplicate alias changeset).
- `enroll`: one Draft per student per `Enrolling.enroll_month/1` call; default `session_ids` = every **scheduled** session of the slot in the month (same as enroll form checkboxes defaulting to all scheduled dates).
- `confirm_payment`: only `state == "claimed"` at propose and apply; `Sales.confirm_payment/2` on apply (same as student/money cycle LiveViews).
- `override_price`: `Sales.update_purchase/2` with `custom_amount` / `note`; apply fails with `:purchase_changed` if `purchase.custom_amount` ≠ `parsed["before_custom_amount"]`.
- `set_no_show`: `Roster.mark_no_show/1` / `mark_expected/1`; apply fails with `:attendance_changed` if `attendance.state` ≠ `parsed["before_state"]`.
- `book_makeup`: `credit_id` required; credit must appear in `Roster.available_credits(student_id, session.date)` at propose and apply; apply fails with `:credit_already_consumed` when spent.
- `add_student`: `People.create_student/1` then `People.add_alias/2` for each alias; duplicate alias → changeset error on apply.
- `save_package`: create when `package_id` omitted (`Catalog.create_package/1`); edit when set (`Catalog.update_package/2` for price, makeups, active, grandfather only); apply fails with `:package_changed` if those fields changed since propose.
- Register all seven tasks on **Teacher chat only** — not `@group` or `@student`.
- Tests: behaviour only; derive display strings from `Format.money/1` when asserting amounts; never assert the complete `@teacher` list — assert **membership** only.
- Every task ends with `mix compile --warnings-as-errors` and its test files green. Final task runs `mix precommit` and real Sonnet via `priv/scripts/line_real_turn.exs`.

## File Structure

| File | Responsibility |
|---|---|
| `lib/ganesha/assistant/tasks/enroll.ex` | `enroll` change task |
| `lib/ganesha/assistant/tasks/confirm_payment.ex` | `confirm_payment` |
| `lib/ganesha/assistant/tasks/override_price.ex` | `override_price` |
| `lib/ganesha/assistant/tasks/set_no_show.ex` | `set_no_show` |
| `lib/ganesha/assistant/tasks/book_makeup.ex` | `book_makeup` |
| `lib/ganesha/assistant/tasks/add_student.ex` | `add_student` |
| `lib/ganesha/assistant/tasks/save_package.ex` | `save_package` |
| `lib/ganesha/assistant/tasks.ex` | Add modules to `@teacher` and `alias` list |
| `lib/ganesha/roster.ex` | `get_attendance/1`, `get_credit/1` |
| `lib/ganesha/sales.ex` | `get_purchase/1`, `get_payment/1` |
| `lib/ganesha/studio.ex` | `get_slot/1` |
| `test/ganesha/assistant/tasks/*_test.exs` | One test module per task |
| `test/ganesha/assistant/tasks_test.exs` | Membership assertions for new tasks |
| `priv/scripts/line_real_turn.exs` | Second argv scenario + richer cleanup |

Task order: getters (1) → task modules with tests (2–8) → registry (9) → real-model script + precommit (10).

---

### Task 1: Non-raising getters for task `propose/2`

**Files:**
- Modify: `lib/ganesha/roster.ex` (after `get_attendance!/1`)
- Modify: `lib/ganesha/sales.ex` (after `get_purchase!/1` and after `alias Ganesha.Sales.Payment`)
- Modify: `lib/ganesha/studio.ex` (after `get_slot!/1`)

**Interfaces:**
- Consumes: existing schemas.
- Produces: `Roster.get_attendance/1`, `Roster.get_credit/1`, `Sales.get_purchase/1`, `Sales.get_payment/1`, `Studio.get_slot/1`.

- [ ] **Step 1: Add the functions**

```elixir
# lib/ganesha/roster.ex — after get_attendance!/1
def get_attendance(id), do: Repo.get(Attendance, id)

def get_credit(id), do: Repo.get(Credit, id)

# lib/ganesha/sales.ex — after get_purchase!/1
def get_purchase(id) do
  Purchase |> Repo.get(id) |> Repo.preload([:student, :package, :slot])
end

# lib/ganesha/sales.ex — after alias Payment
def get_payment(id), do: Repo.get(Payment, id)

# lib/ganesha/studio.ex — after get_slot!/1
def get_slot(id), do: Repo.get(Slot, id)
```

- [ ] **Step 2: Compile**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/ganesha/roster.ex lib/ganesha/sales.ex lib/ganesha/studio.ex
git commit -m "Add non-raising getters for LINE student and money tasks"
```

---

### Task 2: `enroll` task (spec §3.1 #12)

**Files:**
- Create: `lib/ganesha/assistant/tasks/enroll.ex`
- Test: `test/ganesha/assistant/tasks/enroll_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.Enroll` with `name/0` → `"enroll"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.EnrollTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Enroll

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 2,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    # October 2026 has four Tuesdays: 6, 13, 20, 27.
    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-10-01])

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, drop_in} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 500})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      slot: slot,
      sessions: sessions,
      monthly: monthly,
      drop_in: drop_in
    }
  end

  defp input(c, extra \\ %{}) do
    Map.merge(
      %{
        "student_id" => c.student.id,
        "slot_id" => c.slot.id,
        "month" => "2026-10",
        "package_id" => c.monthly.id
      },
      extra
    )
  end

  describe "propose/2" do
    test "takes every scheduled session of the slot in the month and prices them", c do
      {:ok, _} = Studio.cancel_session(Enum.at(c.sessions, 1), "颱風")

      assert {:ok, %{student_id: student_id, parsed: parsed}} = Enroll.propose(input(c), c.ctx)

      assert student_id == c.student.id
      assert parsed["session_ids"] == Enum.map([0, 2, 3], &Enum.at(c.sessions, &1).id)
      assert parsed["session_dates"] == ["2026-10-06", "2026-10-20", "2026-10-27"]
      assert parsed["price"] == 1200
      assert parsed["month"] == "2026-10"
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "takes only the sessions the teacher named", c do
      [first, _, third, _] = c.sessions

      assert {:ok, %{parsed: parsed}} =
               Enroll.propose(input(c, %{"session_ids" => [third.id, first.id]}), c.ctx)

      assert parsed["session_ids"] == [first.id, third.id]
      assert parsed["price"] == 800
    end

    test "rejects a session that is not the slot's in that month", c do
      {:ok, other} = Studio.create_session(%{slot_id: c.slot.id, date: ~D[2026-11-03], style: "Hatha"})

      assert {:error, message} =
               Enroll.propose(input(c, %{"session_ids" => [other.id]}), c.ctx)

      assert message =~ "#{other.id}"
    end

    test "rejects a package that is not monthly", c do
      assert {:error, _} = Enroll.propose(input(c, %{"package_id" => c.drop_in.id}), c.ctx)
    end

    test "rejects a package closed to this student", c do
      {:ok, _} = Catalog.update_package(c.monthly, %{active: false})
      assert {:error, _} = Enroll.propose(input(c), c.ctx)
    end

    test "rejects an inactive student", c do
      {:ok, _} = People.update_student(c.student, %{active: false})
      assert {:error, _} = Enroll.propose(input(c), c.ctx)
    end

    test "rejects a month with no scheduled sessions", c do
      assert {:error, _} = Enroll.propose(input(c, %{"month" => "2026-12"}), c.ctx)
    end

    test "rejects a malformed month", c do
      assert {:error, _} = Enroll.propose(input(c, %{"month" => "October"}), c.ctx)
    end

    test "names the dates the student is already booked on", c do
      [first | _] = c.sessions
      {:ok, _} = Enrolling.add_one_off(first, c.student, c.drop_in, [])

      assert {:error, message} = Enroll.propose(input(c), c.ctx)
      assert message =~ "2026-10-06"
    end

    test "rejects a negative custom amount", c do
      assert {:error, _} = Enroll.propose(input(c, %{"custom_amount" => -1}), c.ctx)
    end
  end

  describe "apply/2" do
    test "creates the purchase, books every session and mints the package credits", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)

      assert {:ok, {"Ganesha.Sales.Purchase", purchase_id}} = Enroll.apply(parsed, "line:teacher")

      purchase = Sales.get_purchase!(purchase_id)
      assert purchase.list_price == 1600
      assert purchase.slot_id == c.slot.id

      for session <- c.sessions do
        assert [%{kind: "enrolled", purchase_id: ^purchase_id}] = Roster.list_for_session(session)
      end

      assert [_credit] = Roster.available_credits(c.student.id, ~D[2026-10-27])
    end

    test "a custom amount is what the purchase owes", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c, %{"custom_amount" => 1500}), c.ctx)
      {:ok, {_, purchase_id}} = Enroll.apply(parsed, "line:teacher")

      assert Sales.payable(Sales.get_purchase!(purchase_id)) == 1500
    end

    test "fails if a session was cancelled after the Draft was made", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Studio.cancel_session(List.last(c.sessions), "颱風")

      assert {:error, :session_cancelled} = Enroll.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "fails if the package was closed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Catalog.update_package(c.monthly, %{active: false})

      assert {:error, :package_unavailable} = Enroll.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "fails if the package price changed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Catalog.update_package(c.monthly, %{price_per_class: 450})

      assert {:error, :price_changed} = Enroll.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "a student booked in the meantime fails the confirm and writes nothing", c do
      {:ok, %{student_id: student_id, parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Enrolling.add_one_off(List.last(c.sessions), c.student, c.drop_in, [])

      {:ok, draft} =
        Assistant.create_draft(c.ctx.thread, %{
          kind: "enroll",
          student_id: student_id,
          parsed: parsed
        })

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(draft, "line:teacher")
      assert failed.state == "failed"
      assert [_one_off] = Sales.list_purchases_for_student(c.student.id)
      assert Roster.list_for_session(hd(c.sessions)) == []
    end
  end

  describe "describe/2" do
    test "shows the slot, the sessions, the package and what is owed", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)

      for locale <- ["zh-TW", "en"] do
        description = Enroll.describe(parsed, locale)

        assert description.title =~ "Lulu"
        assert description.title =~ "基礎"
        assert Enum.any?(description.lines, &(&1 =~ "10/6" and &1 =~ "10/27" and &1 =~ "4"))
        assert Enum.any?(description.lines, &(&1 =~ "月課程" and &1 =~ Format.money(400)))
        assert [{_label, nil, owed}] = description.changes
        assert owed == Format.money(1600)
        assert description.web_path == "/enroll/#{c.slot.id}/2026/10"
      end
    end

    test "shows the custom amount as what is owed", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c, %{"custom_amount" => 1500}), c.ctx)

      assert [{_label, nil, owed}] = Enroll.describe(parsed, "zh-TW").changes
      assert owed == Format.money(1500)
    end
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/enroll_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.Enroll do
  @moduledoc """
  `enroll` (spec §3.1 #12): one Enrollment per Draft — a student in one Slot
  for a month's Sessions on a monthly Package, through
  `Ganesha.Enrolling.enroll_month/1`, as the web enroll screen does.
  "Several students" means several calls, one Draft each.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @apply_keys ~w(student_id slot_id package_id session_ids custom_amount note)

  @impl true
  def name, do: "enroll"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Enroll one student in one weekly Slot for a month on a monthly package (報名月課程). \
      This only proposes a Draft; the purchase and the bookings are created when the \
      teacher taps Confirm. For several students, call once per student. Use ids from the \
      studio snapshot. Omit session_ids to book every scheduled Session of that Slot in \
      the month, as the web screen does.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          slot_id: %{type: "integer"},
          month: %{type: "string", description: "The month as YYYY-MM, e.g. 2026-10"},
          package_id: %{type: "integer", description: "A monthly package"},
          session_ids: %{
            type: "array",
            items: %{type: "integer"},
            description: "Only these Sessions of the Slot in that month, if the teacher says so"
          },
          custom_amount: %{
            type: "integer",
            description: "NT$ owed instead of the package price, only if the teacher says so"
          },
          note: %{type: "string"}
        },
        required: ["student_id", "slot_id", "month", "package_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, student} <- fetch(:student, input["student_id"]),
         :ok <- check_active(student),
         {:ok, slot} <- fetch(:slot, input["slot_id"]),
         {:ok, month} <- parse_month(input["month"]),
         {:ok, package} <- fetch(:package, input["package_id"]),
         :ok <- check_monthly(package),
         :ok <- check_available(package, student),
         :ok <- check_amount(input["custom_amount"]),
         scheduled =
           slot |> Studio.sessions_for_slot_in_month(month) |> Enum.filter(&scheduled?/1),
         {:ok, sessions} <- pick_sessions(scheduled, input["session_ids"], slot, month),
         :ok <- check_not_booked(sessions, student) do
      parsed = %{
        "student_id" => student.id,
        "slot_id" => slot.id,
        "package_id" => package.id,
        "session_ids" => Enum.map(sessions, & &1.id),
        "custom_amount" => input["custom_amount"],
        "note" => input["note"],
        "student_name" => student.display_name,
        "slot_label" => Fmt.slot_title(slot.label),
        "slot_weekday" => slot.weekday,
        "slot_time" => Fmt.time_range(slot.start_time, slot.end_time),
        "month" => Calendar.strftime(month, "%Y-%m"),
        "session_dates" => Enum.map(sessions, &Date.to_iso8601(&1.date)),
        "package_name" => package.name,
        "price_per_class" => package.price_per_class,
        "price" => Catalog.price_for(package, length(sessions))
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <- load(:student, attrs["student_id"]),
         {:ok, slot} <- load(:slot, attrs["slot_id"]),
         {:ok, package} <- load(:package, attrs["package_id"]),
         {:ok, sessions} <- load_sessions(attrs["session_ids"]),
         :ok <- still_scheduled(sessions),
         :ok <- still_available(package, student),
         :ok <- same_price(package, length(sessions), parsed["price"]),
         {:ok, %{purchase: purchase}} <-
           Enrolling.enroll_month(%{
             student: student,
             slot: slot,
             package: package,
             sessions: sessions,
             custom_amount: attrs["custom_amount"],
             note: attrs["note"]
           }) do
      {:ok, {"Ganesha.Sales.Purchase", purchase.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    dates = Enum.flat_map(parsed["session_dates"] || [], &parse_date/1)
    month = parse_month_text(parsed["month"])

    %{
      title:
        Enum.join(
          [
            title(locale),
            parsed["student_name"],
            month_text(month, locale),
            weekday_text(parsed["slot_weekday"], locale),
            parsed["slot_label"]
          ]
          |> Enum.reject(&(&1 in [nil, ""])),
          " "
        ),
      lines:
        Enum.reject(
          [
            slot_line(parsed, locale),
            sessions_line(dates, locale),
            package_line(parsed, locale),
            note_line(parsed["note"], locale)
          ],
          &is_nil/1
        ),
      changes: [{owed_label(locale), nil, Format.money(parsed["custom_amount"] || parsed["price"])}],
      web_path: web_path(parsed["slot_id"], month)
    }
  end

  defp fetch(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, "no #{what} with id #{id}; use an id from the snapshot"}
      record -> {:ok, record}
    end
  end

  defp fetch(what, _id), do: {:error, "#{what}_id must be an integer id from the snapshot"}

  defp load(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp load(_what, _id), do: {:error, :not_found}

  defp get(:student, id), do: People.get_student(id)
  defp get(:slot, id), do: Studio.get_slot(id)
  defp get(:package, id), do: Catalog.get_package(id)
  defp get(:session, id), do: Studio.get_session(id)

  defp load_sessions(ids) when is_list(ids) and ids != [] do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, sessions} ->
      case load(:session, id) do
        {:ok, session} -> {:cont, {:ok, sessions ++ [session]}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_sessions(_ids), do: {:error, :no_sessions}

  defp check_active(%{active: true}), do: :ok
  defp check_active(student), do: {:error, "#{student.display_name} is inactive"}

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text <> "-01") do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "month must be YYYY-MM, e.g. 2026-10"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be YYYY-MM, e.g. 2026-10"}

  defp check_monthly(%{kind: "monthly"}), do: :ok

  defp check_monthly(package),
    do: {:error, "#{package.name} is not a monthly package; use book_one_off for 單堂 or 體驗"}

  defp check_available(package, student) do
    if available?(package, student),
      do: :ok,
      else: {:error, "#{package.name} is closed to #{student.display_name}"}
  end

  defp still_available(package, student) do
    if available?(package, student), do: :ok, else: {:error, :package_unavailable}
  end

  defp available?(package, student),
    do: Catalog.package_available?(package, Sales.purchased_package_ids_for_student(student.id))

  defp same_price(package, count, price) do
    if Catalog.price_for(package, count) == price, do: :ok, else: {:error, :price_changed}
  end

  defp check_amount(nil), do: :ok
  defp check_amount(amount) when is_integer(amount) and amount >= 0, do: :ok

  defp check_amount(_amount),
    do: {:error, "custom_amount must be a whole NT$ amount of 0 or more"}

  defp scheduled?(session), do: session.state == "scheduled"

  defp still_scheduled(sessions) do
    if Enum.all?(sessions, &scheduled?/1), do: :ok, else: {:error, :session_cancelled}
  end

  defp pick_sessions([], _ids, slot, month),
    do:
      {:error,
       "slot #{slot.id} has no scheduled sessions in #{Calendar.strftime(month, "%Y-%m")}"}

  defp pick_sessions(scheduled, nil, _slot, _month), do: {:ok, scheduled}

  defp pick_sessions(scheduled, ids, slot, month) when is_list(ids) and ids != [] do
    case Enum.reject(ids, fn id -> Enum.any?(scheduled, &(&1.id == id)) end) do
      [] ->
        {:ok, Enum.filter(scheduled, &(&1.id in ids))}

      unknown ->
        {:error,
         "sessions #{Enum.join(unknown, ", ")} are not scheduled sessions of slot #{slot.id} " <>
           "in #{Calendar.strftime(month, "%Y-%m")}; its scheduled sessions are " <>
           Enum.map_join(scheduled, ", ", &"#{&1.id} (#{Date.to_iso8601(&1.date)})")}
    end
  end

  defp pick_sessions(_scheduled, _ids, _slot, _month),
    do: {:error, "session_ids must be a non-empty list of session ids, or omitted"}

  defp check_not_booked(sessions, student) do
    booked =
      Enum.filter(sessions, fn session ->
        session |> Roster.list_for_session() |> Enum.any?(&(&1.student_id == student.id))
      end)

    case booked do
      [] ->
        :ok

      booked ->
        {:error,
         "#{student.display_name} is already booked on " <>
           Enum.map_join(booked, ", ", &Date.to_iso8601(&1.date)) <>
           "; pass session_ids without those sessions, or ask the teacher"}
    end
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> [date]
      {:error, _} -> []
    end
  end

  defp parse_date(_iso), do: []

  defp parse_month_text(text) when is_binary(text) do
    case Date.from_iso8601(text <> "-01") do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_month_text(_text), do: nil

  defp title("en"), do: "Enroll"
  defp title(_locale), do: "報名"

  defp month_text(nil, _locale), do: nil
  defp month_text(month, "en"), do: Calendar.strftime(month, "%b")
  defp month_text(month, _locale), do: "#{month.month}月"

  defp weekday_text(day, "en") when day in 1..7,
    do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), day - 1)

  defp weekday_text(day, _locale) when day in 1..7, do: Fmt.weekday(day)
  defp weekday_text(_day, _locale), do: nil

  defp slot_line(parsed, "en"),
    do:
      "Class: #{weekday_text(parsed["slot_weekday"], "en")} #{parsed["slot_time"]} " <>
        "#{parsed["slot_label"]}"

  defp slot_line(parsed, _locale),
    do:
      "固定班：#{weekday_text(parsed["slot_weekday"], "zh-TW")} #{parsed["slot_time"]} " <>
        "#{parsed["slot_label"]}"

  defp sessions_line([], _locale), do: nil

  defp sessions_line(dates, "en"),
    do: "Sessions: #{Enum.map_join(dates, ", ", &Fmt.short_date/1)} (#{length(dates)})"

  defp sessions_line(dates, _locale),
    do: "課堂：#{Enum.map_join(dates, "、", &Fmt.short_date/1)}（#{length(dates)} 堂）"

  defp package_line(parsed, "en"),
    do:
      "Package: #{parsed["package_name"]} #{Format.money(parsed["price_per_class"])}/class, " <>
        "list #{Format.money(parsed["price"])}"

  defp package_line(parsed, _locale),
    do:
      "方案：#{parsed["package_name"]} #{Format.money(parsed["price_per_class"])}／堂，" <>
        "原價 #{Format.money(parsed["price"])}"

  defp note_line(note, _locale) when note in [nil, ""], do: nil
  defp note_line(note, "en"), do: "Note: #{note}"
  defp note_line(note, _locale), do: "備註：#{note}"

  defp owed_label("en"), do: "Owed"
  defp owed_label(_locale), do: "應付"

  defp web_path(slot_id, %Date{} = month) when is_integer(slot_id),
    do: "/enroll/#{slot_id}/#{month.year}/#{month.month}"

  defp web_path(_slot_id, _month), do: nil
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/enroll_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/enroll.ex test/ganesha/assistant/tasks/enroll_test.exs
git commit -m "Add enroll LINE assistant task"
```

---

### Task 3: `confirm_payment` task (spec §3.1 #15)

**Files:**
- Create: `lib/ganesha/assistant/tasks/confirm_payment.ex`
- Test: `test/ganesha/assistant/tasks/confirm_payment_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.ConfirmPayment` with `name/0` → `"confirm_payment"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.ConfirmPaymentTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Tasks.ConfirmPayment

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 1600})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 800,
        method: "line_pay",
        paid_on: ~D[2026-10-02],
        source: "manual"
      })

    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}, student: student, payment: payment}
  end

  describe "propose/2" do
    test "captures the claimed payment", c do
      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      assert student_id == c.student.id
      assert parsed["amount"] == 800
      assert parsed["before_state"] == "claimed"
      assert c.payment.state == "claimed"
    end

    test "rejects a confirmed payment", c do
      {:ok, _} = Sales.confirm_payment(c.payment, "teacher@example.com")

      assert {:error, message} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)
      assert message =~ "confirmed"
    end
  end

  describe "apply/2" do
    test "confirms the payment", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      assert {:ok, {"Ganesha.Sales.Payment", payment_id}} =
               ConfirmPayment.apply(parsed, "line:teacher")

      assert Sales.get_payment(payment_id).state == "confirmed"
    end

    test "fails if the payment was confirmed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)
      {:ok, _} = Sales.confirm_payment(c.payment, "teacher@example.com")

      assert {:error, :payment_not_claimed} = ConfirmPayment.apply(parsed, "line:teacher")
    end
  end

  describe "describe/2" do
    test "shows the state change", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      assert %{changes: [{"狀態", "待確認", "已確認"}]} = ConfirmPayment.describe(parsed, "zh-TW")
    end
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/confirm_payment_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.ConfirmPayment do
  @moduledoc """
  `confirm_payment` (spec §3.1 #15): confirm a claimed payment that was
  recorded on the web, through `Ganesha.Sales.confirm_payment/2`, as the
  student and money cycle screens do.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Sales}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @apply_keys ~w(payment_id)

  @impl true
  def name, do: "confirm_payment"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Confirm that a payment the teacher recorded on the web has actually arrived. \
      This only proposes a Draft; the payment is confirmed when she taps Confirm. \
      Use payment_id from the studio snapshot or from student_summary. Only claimed \
      payments can be confirmed.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          payment_id: %{type: "integer", description: "A payment in state claimed"}
        },
        required: ["payment_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, payment} <- fetch_payment(input["payment_id"]),
         :ok <- check_claimed(payment),
         purchase <- Sales.get_purchase!(payment.purchase_id),
         student <- People.get_student!(purchase.student_id) do
      parsed = %{
        "payment_id" => payment.id,
        "purchase_id" => purchase.id,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "package_name" => purchase.package.name,
        "amount" => payment.amount,
        "method" => payment.method,
        "paid_on" => Date.to_iso8601(payment.paid_on),
        "before_state" => payment.state
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, payment} <- load_payment(attrs["payment_id"]),
         :ok <- still_claimed(payment),
         {:ok, confirmed} <- Sales.confirm_payment(payment, confirmed_by) do
      {:ok, {"Ganesha.Sales.Payment", confirmed.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    %{
      title:
        "#{label(:title, locale)} #{parsed["student_name"]} #{Format.money(parsed["amount"])}",
      lines:
        Enum.reject(
          [
            line(:package, parsed["package_name"], locale),
            line(:method, method_name(parsed["method"], locale), locale),
            line(:paid_on, date_text(parsed["paid_on"], locale), locale)
          ],
          &is_nil/1
        ),
      changes: [
        {label(:state, locale), state_name(parsed["before_state"], locale),
         state_name("confirmed", locale)}
      ],
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

  defp fetch_payment(id) when is_integer(id) do
    case Sales.get_payment(id) do
      nil -> {:error, "no payment with id #{id}"}
      payment -> {:ok, payment}
    end
  end

  defp fetch_payment(_id), do: {:error, "payment_id must be an integer"}

  defp load_payment(id) when is_integer(id) do
    case Sales.get_payment(id) do
      nil -> {:error, :not_found}
      payment -> {:ok, payment}
    end
  end

  defp load_payment(_id), do: {:error, :not_found}

  defp check_claimed(%{state: "claimed"}), do: :ok
  defp check_claimed(%{state: state}), do: {:error, "payment is already #{state}, not claimed"}

  defp still_claimed(%{state: "claimed"}), do: :ok
  defp still_claimed(_payment), do: {:error, :payment_not_claimed}

  defp label(:title, "en"), do: "Confirm payment"
  defp label(:title, _), do: "確認收款"
  defp label(:package, "en"), do: "Package"
  defp label(:package, _), do: "方案"
  defp label(:method, "en"), do: "Method"
  defp label(:method, _), do: "付款方式"
  defp label(:paid_on, "en"), do: "Paid on"
  defp label(:paid_on, _), do: "付款日"
  defp label(:state, "en"), do: "State"
  defp label(:state, _), do: "狀態"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp method_name(nil, _locale), do: nil
  defp method_name("line_pay", "en"), do: "LINE Pay"
  defp method_name("line_bank", "en"), do: "LINE Bank"
  defp method_name("cash", "en"), do: "Cash"
  defp method_name("other", "en"), do: "Other"
  defp method_name(method, "en"), do: method
  defp method_name(method, _locale), do: Fmt.method(method)

  defp date_text(nil, _locale), do: nil
  defp date_text(iso, "en"), do: iso

  defp date_text(iso, _locale) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Fmt.date(date)
      {:error, _} -> iso
    end
  end

  defp state_name("claimed", "en"), do: "Claimed"
  defp state_name("confirmed", "en"), do: "Confirmed"
  defp state_name("disputed", "en"), do: "Disputed"
  defp state_name("claimed", _), do: "待確認"
  defp state_name("confirmed", _), do: "已確認"
  defp state_name("disputed", _), do: "有疑義"
  defp state_name(other, _), do: other
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/confirm_payment_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/confirm_payment.ex test/ganesha/assistant/tasks/confirm_payment_test.exs
git commit -m "Add confirm_payment LINE assistant task"
```

---

### Task 4: `override_price` task (spec §3.1 #16)

**Files:**
- Create: `lib/ganesha/assistant/tasks/override_price.ex`
- Test: `test/ganesha/assistant/tasks/override_price_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.OverridePrice` with `name/0` → `"override_price"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.OverridePriceTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.OverridePrice

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 1600})

    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}, student: student, purchase: purchase}
  end

  test "propose captures payable before and after", c do
    assert {:ok, %{parsed: parsed}} =
             OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    assert parsed["before_payable"] == 1600
    assert parsed["after_payable"] == 1500
    assert parsed["before_custom_amount"] == nil
  end

  test "apply updates the purchase", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    assert {:ok, {_, purchase_id}} = OverridePrice.apply(parsed, "line:teacher")
    assert Sales.payable(Sales.get_purchase!(purchase_id)) == 1500
  end

  test "apply fails if custom_amount changed after propose", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    {:ok, _} = Sales.update_purchase(c.purchase, %{custom_amount: 1400})
    assert {:error, :purchase_changed} = OverridePrice.apply(parsed, "line:teacher")
  end

  test "describe shows owed before → after", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    assert [{_, before, after_value}] = OverridePrice.describe(parsed, "zh-TW").changes
    assert before == Format.money(1600)
    assert after_value == Format.money(1500)
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/override_price_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.OverridePrice do
  @moduledoc """
  `override_price` (spec §3.1 #16): set or clear a purchase's
  `custom_amount` through `Ganesha.Sales.update_purchase/2`, as the student
  screen's override form does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Sales
  alias Ganesha.Assistant.Format

  @apply_keys ~w(purchase_id custom_amount note)

  @impl true
  def name, do: "override_price"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Override what a student owes on a purchase (議價). This only proposes a Draft; \
      the purchase is updated when the teacher taps Confirm. Pass custom_amount to \
      set the agreed NT$ total, or omit it / pass null to clear the override back to \
      list price. Use purchase_id from the studio snapshot or student_summary.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          purchase_id: %{type: "integer"},
          custom_amount: %{
            type: ["integer", "null"],
            description: "NT$ owed instead of list price; null clears the override"
          },
          note: %{type: "string"}
        },
        required: ["purchase_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, purchase} <- fetch_purchase(input["purchase_id"]),
         :ok <- check_amount(input["custom_amount"]) do
      student = purchase.student
      before_payable = Sales.payable(purchase)
      after_payable = after_payable(purchase, input["custom_amount"])

      parsed = %{
        "purchase_id" => purchase.id,
        "custom_amount" => blank_amount(input["custom_amount"]),
        "note" => input["note"],
        "student_id" => student.id,
        "student_name" => student.display_name,
        "package_name" => purchase.package.name,
        "list_price" => purchase.list_price,
        "before_custom_amount" => purchase.custom_amount,
        "before_payable" => before_payable,
        "after_payable" => after_payable
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, purchase} <- load_purchase(attrs["purchase_id"]),
         :ok <- same_custom_amount(purchase, parsed["before_custom_amount"]),
         {:ok, updated} <-
           Sales.update_purchase(purchase, %{
             custom_amount: attrs["custom_amount"],
             note: attrs["note"]
           }) do
      {:ok, {"Ganesha.Sales.Purchase", updated.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    %{
      title:
        "#{label(:title, locale)} #{parsed["student_name"]} #{parsed["package_name"]}",
      lines:
        Enum.reject(
          [
            line(:list_price, Format.money(parsed["list_price"]), locale),
            note_line(parsed["note"], locale)
          ],
          &is_nil/1
        ),
      changes: [
        {label(:owed, locale), Format.money(parsed["before_payable"]),
         Format.money(parsed["after_payable"])}
      ],
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

  defp fetch_purchase(id) when is_integer(id) do
    case Sales.get_purchase(id) do
      nil -> {:error, "no purchase with id #{id}"}
      purchase -> {:ok, purchase}
    end
  end

  defp fetch_purchase(_id), do: {:error, "purchase_id must be an integer"}

  defp load_purchase(id) when is_integer(id) do
    case Sales.get_purchase(id) do
      nil -> {:error, :not_found}
      purchase -> {:ok, purchase}
    end
  end

  defp load_purchase(_id), do: {:error, :not_found}

  defp check_amount(nil), do: :ok
  defp check_amount(amount) when is_integer(amount) and amount >= 0, do: :ok

  defp check_amount(_amount),
    do: {:error, "custom_amount must be a whole NT$ amount of 0 or more, or null to clear"}

  defp blank_amount(nil), do: nil
  defp blank_amount(amount), do: amount

  defp after_payable(purchase, nil), do: purchase.list_price
  defp after_payable(_purchase, amount) when is_integer(amount), do: amount

  defp same_custom_amount(%{custom_amount: current}, expected) do
    if current == expected, do: :ok, else: {:error, :purchase_changed}
  end

  defp label(:title, "en"), do: "Override price"
  defp label(:title, _), do: "議價"
  defp label(:list_price, "en"), do: "List price"
  defp label(:list_price, _), do: "原價"
  defp label(:owed, "en"), do: "Owed"
  defp label(:owed, _), do: "應付"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp note_line(note, _locale) when note in [nil, ""], do: nil
  defp note_line(note, "en"), do: "Note: #{note}"
  defp note_line(note, _locale), do: "備註：#{note}"
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/override_price_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/override_price.ex test/ganesha/assistant/tasks/override_price_test.exs
git commit -m "Add override_price LINE assistant task"
```

---

### Task 5: `set_no_show` task (spec §3.1 #17)

**Files:**
- Create: `lib/ganesha/assistant/tasks/set_no_show.ex`
- Test: `test/ganesha/assistant/tasks/set_no_show_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.SetNoShow` with `name/0` → `"set_no_show"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.SetNoShowTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, Enrolling, People, Roster, Studio}
  alias Ganesha.Assistant.Tasks.SetNoShow

  setup do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
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

    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, _} = Enrolling.add_one_off(session, student, package, [])
    attendance = hd(Roster.list_for_session(session))

    %{ctx: %{locale: "zh-TW", today: ~D[2026-10-02]}, attendance: attendance, session: session}
  end

  test "marks no-show and can undo", c do
    assert {:ok, %{parsed: parsed}} =
             SetNoShow.propose(
               %{"attendance_id" => c.attendance.id, "state" => "no_show"},
               c.ctx
             )

    assert {:ok, _} = SetNoShow.apply(parsed, "line:teacher")
    assert Roster.get_attendance!(c.attendance.id).state == "no_show"

    assert {:ok, %{parsed: undo}} =
             SetNoShow.propose(
               %{"attendance_id" => c.attendance.id, "state" => "expected"},
               c.ctx
             )

    assert {:ok, _} = SetNoShow.apply(undo, "line:teacher")
    assert Roster.get_attendance!(c.attendance.id).state == "expected"
  end

  test "propose rejects when already in that state", c do
    assert {:error, _} =
             SetNoShow.propose(
               %{"attendance_id" => c.attendance.id, "state" => "expected"},
               c.ctx
             )
  end

  test "apply fails if attendance changed after propose", c do
    {:ok, %{parsed: parsed}} =
      SetNoShow.propose(%{"attendance_id" => c.attendance.id, "state" => "no_show"}, c.ctx)

    {:ok, _} = Roster.mark_no_show(c.attendance)
    assert {:error, :attendance_changed} = SetNoShow.apply(parsed, "line:teacher")
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/set_no_show_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.SetNoShow do
  @moduledoc """
  `set_no_show` (spec §3.1 #17): mark an attendance as a no-show or undo it
  through `Ganesha.Roster.mark_no_show/1` and `mark_expected/1`, as the
  session screen's toggle does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Roster, Studio}
  alias GaneshaWeb.Fmt

  @apply_keys ~w(attendance_id state)

  @impl true
  def name, do: "set_no_show"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Mark a student as a no-show on one Session, or undo a no-show back to expected. \
      This only proposes a Draft; the attendance row is updated when the teacher taps \
      Confirm. Use attendance_id from session_roster or the studio snapshot.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          attendance_id: %{type: "integer"},
          state: %{
            type: "string",
            enum: ["no_show", "expected"],
            description: "no_show to mark absent; expected to undo"
          }
        },
        required: ["attendance_id", "state"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, attendance} <- fetch_attendance(input["attendance_id"]),
         :ok <- check_state(input["state"]),
         :ok <- check_transition(attendance, input["state"]),
         session <- Studio.get_session!(attendance.session_id),
         student <- People.get_student!(attendance.student_id) do
      parsed = %{
        "attendance_id" => attendance.id,
        "session_id" => session.id,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "before_state" => attendance.state,
        "state" => input["state"]
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, attendance} <- load_attendance(attrs["attendance_id"]),
         :ok <- same_state(attendance, parsed["before_state"]),
         {:ok, updated} <- apply_state(attendance, attrs["state"]) do
      {:ok, {"Ganesha.Roster.Attendance", updated.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title:
        "#{title(parsed["state"], locale)} #{parsed["student_name"]} #{short_date(date, locale)}",
      lines:
        Enum.reject(
          [
            session_line(parsed, date, locale),
            kind_line(parsed, locale)
          ],
          &is_nil/1
        ),
      changes: [
        {label(:attendance, locale), state_name(parsed["before_state"], locale),
         state_name(parsed["state"], locale)}
      ],
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp fetch_attendance(id) when is_integer(id) do
    case Roster.get_attendance(id) do
      nil -> {:error, "no attendance with id #{id}"}
      attendance -> {:ok, attendance}
    end
  end

  defp fetch_attendance(_id), do: {:error, "attendance_id must be an integer"}

  defp load_attendance(id) when is_integer(id) do
    case Roster.get_attendance(id) do
      nil -> {:error, :not_found}
      attendance -> {:ok, attendance}
    end
  end

  defp load_attendance(_id), do: {:error, :not_found}

  defp check_state(state) when state in ["no_show", "expected"], do: :ok
  defp check_state(_state), do: {:error, "state must be no_show or expected"}

  defp check_transition(%{state: current}, desired) when current == desired do
    {:error, "attendance is already #{desired}"}
  end

  defp check_transition(_attendance, _desired), do: :ok

  defp same_state(%{state: current}, before) when current == before, do: :ok
  defp same_state(_attendance, _before), do: {:error, :attendance_changed}

  defp apply_state(attendance, "no_show"), do: Roster.mark_no_show(attendance)
  defp apply_state(attendance, "expected"), do: Roster.mark_expected(attendance)

  defp parse_date(nil), do: nil

  defp parse_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp short_date(nil, _locale), do: ""
  defp short_date(date, _locale), do: Fmt.short_date(date)

  defp title("no_show", "en"), do: "No-show"
  defp title("expected", "en"), do: "Undo no-show"
  defp title("no_show", _), do: "缺席"
  defp title("expected", _), do: "取消缺席"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, _locale),
    do:
      "課堂：#{Fmt.short_date(date)} #{Fmt.weekday(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp kind_line(_parsed, _locale), do: nil

  defp label(:attendance, "en"), do: "Attendance"
  defp label(:attendance, _), do: "出席"

  defp state_name("expected", "en"), do: "Expected"
  defp state_name("no_show", "en"), do: "No-show"
  defp state_name("expected", _), do: "預期出席"
  defp state_name("no_show", _), do: "缺席"
  defp state_name(other, _), do: other
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/set_no_show_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/set_no_show.ex test/ganesha/assistant/tasks/set_no_show_test.exs
git commit -m "Add set_no_show LINE assistant task"
```

---

### Task 6: `book_makeup` task (spec §3.1 #18)

**Files:**
- Create: `lib/ganesha/assistant/tasks/book_makeup.ex`
- Test: `test/ganesha/assistant/tasks/book_makeup_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.BookMakeup` with `name/0` → `"book_makeup"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.BookMakeupTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, Enrolling, People, Roster, Studio}
  alias Ganesha.Assistant.Tasks.BookMakeup

  setup do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 4,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, enroll_session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-01], style: "Hatha"})

    {:ok, makeup_session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-08], style: "Hatha"})

    {:ok, monthly} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: student,
        slot: slot,
        package: monthly,
        sessions: [enroll_session],
        custom_amount: nil,
        note: nil
      })

    [credit] = Roster.available_credits(student.id, makeup_session.date)

    %{ctx: %{locale: "zh-TW", today: ~D[2026-10-02]}, student: student, session: makeup_session, credit: credit}
  end

  test "books a makeup and spends the credit", c do
    input = %{
      "student_id" => c.student.id,
      "session_id" => c.session.id,
      "credit_id" => c.credit.id
    }

    assert {:ok, %{parsed: parsed}} = BookMakeup.propose(input, c.ctx)
    assert {:ok, {_, attendance_id}} = BookMakeup.apply(parsed, "line:teacher")

    assert [%{id: ^attendance_id, kind: "makeup"}] = Roster.list_for_session(c.session)
    assert Roster.get_credit(c.credit.id).consumed_by_attendance_id == attendance_id
  end

  test "apply fails if the credit was spent after propose", c do
    {:ok, other} =
      Studio.create_session(%{slot_id: slot_id(c.session), date: ~D[2026-10-15], style: "Hatha"})

    input = %{
      "student_id" => c.student.id,
      "session_id" => c.session.id,
      "credit_id" => c.credit.id
    }

    {:ok, %{parsed: parsed}} = BookMakeup.propose(input, c.ctx)
    {:ok, _} = Roster.book_makeup(other, c.student, c.credit)

    assert {:error, :credit_already_consumed} = BookMakeup.apply(parsed, "line:teacher")
    assert Roster.list_for_session(c.session) == []
  end

  defp slot_id(session) do
    session = Studio.get_session!(session.id)
    session.slot_id
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/book_makeup_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.BookMakeup do
  @moduledoc """
  `book_makeup` (spec §3.1 #18): spend a Credit on a Session through
  `Ganesha.Roster.book_makeup/3`, as the session screen does with the first
  available credit for that date.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Roster, Studio}
  alias GaneshaWeb.Fmt

  @apply_keys ~w(session_id student_id credit_id)

  @impl true
  def name, do: "book_makeup"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Book a makeup class for a student into one Session using one of their open \
      Credits. This only proposes a Draft; the makeup attendance and the spent credit \
      are created when the teacher taps Confirm. Use session_id, student_id and \
      credit_id from the studio snapshot or open_credits / student_summary. The \
      credit must still be unspent and valid on the session date.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          session_id: %{type: "integer"},
          credit_id: %{type: "integer"}
        },
        required: ["student_id", "session_id", "credit_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, student} <- fetch(:student, input["student_id"]),
         {:ok, session} <- fetch(:session, input["session_id"]),
         :ok <- check_scheduled(session),
         {:ok, credit} <- fetch_credit(input["credit_id"], student, session),
         roster = Roster.list_for_session(session),
         :ok <- check_not_booked(roster, student) do
      parsed = %{
        "student_id" => student.id,
        "session_id" => session.id,
        "credit_id" => credit.id,
        "student_name" => student.display_name,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "credit_source" => credit.source,
        "credit_expires_on" =>
          if(credit.expires_on, do: Date.to_iso8601(credit.expires_on), else: nil),
        "before_count" => length(roster)
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <- load(:student, attrs["student_id"]),
         {:ok, session} <- load(:session, attrs["session_id"]),
         :ok <- still_scheduled(session),
         {:ok, credit} <- load_credit(attrs["credit_id"], student, session),
         :ok <- credit_still_available(credit),
         {:ok, attendance} <- Roster.book_makeup(session, student, credit) do
      {:ok, {"Ganesha.Roster.Attendance", attendance.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title: "#{title(locale)} #{parsed["student_name"]} #{short_date(date)}",
      lines:
        Enum.reject(
          [
            session_line(parsed, date, locale),
            credit_line(parsed, locale)
          ],
          &is_nil/1
        ),
      changes: roster_change(parsed["before_count"], locale),
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp fetch(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, "no #{what} with id #{id}; use an id from the snapshot"}
      record -> {:ok, record}
    end
  end

  defp fetch(what, _id), do: {:error, "#{what}_id must be an integer id from the snapshot"}

  defp load(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp load(_what, _id), do: {:error, :not_found}

  defp get(:student, id), do: People.get_student(id)
  defp get(:session, id), do: Studio.get_session(id)

  defp fetch_credit(id, student, session) when is_integer(id) do
    case Roster.get_credit(id) do
      nil ->
        {:error, "no credit with id #{id}"}

      credit ->
        with :ok <- credit_usable?(credit, student, session), do: {:ok, credit}
    end
  end

  defp fetch_credit(_id, _student, _session), do: {:error, "credit_id must be an integer"}

  defp load_credit(id, student, session) when is_integer(id) do
    case Roster.get_credit(id) do
      nil ->
        {:error, :not_found}

      %{consumed_by_attendance_id: consumed} when not is_nil(consumed) ->
        {:error, :credit_already_consumed}

      credit ->
        case credit_usable?(credit, student, session) do
          :ok -> {:ok, credit}
          error -> error
        end
    end
  end

  defp load_credit(_id, _student, _session), do: {:error, :not_found}

  defp credit_usable?(credit, student, session) do
    available = Roster.available_credits(student.id, session.date)

    cond do
      credit.student_id != student.id ->
        {:error, "credit #{credit.id} does not belong to #{student.display_name}"}

      not Enum.any?(available, &(&1.id == credit.id)) ->
        {:error, "credit #{credit.id} is not available on #{Date.to_iso8601(session.date)}"}

      true ->
        :ok
    end
  end

  defp credit_still_available(credit) do
    if is_nil(credit.consumed_by_attendance_id), do: :ok, else: {:error, :credit_already_consumed}
  end

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_not_booked(roster, student) do
    if Enum.any?(roster, &(&1.student_id == student.id)),
      do: {:error, "#{student.display_name} is already booked in that session"},
      else: :ok
  end

  defp parse_date(nil), do: nil

  defp parse_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp short_date(nil), do: ""
  defp short_date(date), do: Fmt.short_date(date)

  defp title("en"), do: "Makeup"
  defp title(_locale), do: "補課"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, _locale),
    do:
      "課堂：#{Fmt.short_date(date)} #{Fmt.weekday(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp credit_line(parsed, "en"),
    do:
      "Credit: #{parsed["credit_source"]}" <>
        expiry_text(parsed["credit_expires_on"], "en")

  defp credit_line(parsed, _locale),
    do:
      "補課券：#{credit_source(parsed["credit_source"])}" <>
        expiry_text(parsed["credit_expires_on"], "zh-TW")

  defp expiry_text(nil, _locale), do: " (no expiry)"
  defp expiry_text(iso, "en"), do: " (expires #{iso})"

  defp expiry_text(iso, _locale) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> "（#{Fmt.short_date(date)} 到期）"
      {:error, _} -> "（#{iso} 到期）"
    end
  end

  defp credit_source("package"), do: "方案"
  defp credit_source("cancellation"), do: "停課"
  defp credit_source(other), do: other

  defp roster_change(count, "en") when is_integer(count),
    do: [{"Roster", "#{count}", "#{count + 1}"}]

  defp roster_change(count, _locale) when is_integer(count),
    do: [{"名單", "#{count} 人", "#{count + 1} 人"}]

  defp roster_change(_count, _locale), do: []
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/book_makeup_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/book_makeup.ex test/ganesha/assistant/tasks/book_makeup_test.exs
git commit -m "Add book_makeup LINE assistant task"
```

---

### Task 7: `add_student` task (spec §3.1 #19)

**Files:**
- Create: `lib/ganesha/assistant/tasks/add_student.ex`
- Test: `test/ganesha/assistant/tasks/add_student_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.AddStudent` with `name/0` → `"add_student"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.AddStudentTest do
  use Ganesha.DataCase

  alias Ganesha.{People, Repo}
  alias Ganesha.Assistant.Tasks.AddStudent
  alias Ganesha.People.StudentAlias

  test "creates the student and aliases on apply" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}

    assert {:ok, %{parsed: parsed}} =
             AddStudent.propose(%{"display_name" => "Amy", "aliases" => ["小艾"]}, ctx)

    assert {:ok, {"Ganesha.People.Student", student_id}} = AddStudent.apply(parsed, "line:teacher")
    assert People.get_student!(student_id).display_name == "Amy"
    assert Repo.get_by(StudentAlias, student_id: student_id, alias: "小艾")
  end

  test "apply returns changeset error on duplicate alias" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}
    {:ok, student} = People.create_student(%{display_name: "Taken"})
    {:ok, _} = People.add_alias(student, "小艾")

    assert {:ok, %{parsed: parsed}} =
             AddStudent.propose(%{"display_name" => "Amy", "aliases" => ["小艾"]}, ctx)

    assert {:error, %Ecto.Changeset{}} = AddStudent.apply(parsed, "line:teacher")
    refute People.find_by_alias("Amy")
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/add_student_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.AddStudent do
  @moduledoc """
  `add_student` (spec §3.1 #19): create a student and optional aliases through
  `Ganesha.People.create_student/1` and `add_alias/2`, as the students index
  screen does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, People}

  @apply_keys ~w(display_name line_user_id aliases)

  @impl true
  def name, do: "add_student"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Add a new student to the studio. This only proposes a Draft; the student \
      (and any aliases) are created when the teacher taps Confirm. Aliases help \
      match LINE messages to this student later.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          display_name: %{type: "string"},
          line_user_id: %{type: "string", description: "Their LINE user id, if known"},
          aliases: %{
            type: "array",
            items: %{type: "string"},
            description: "Other names she uses for this student"
          }
        },
        required: ["display_name"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, display_name} <- require_name(input["display_name"]),
         {:ok, aliases} <- normalize_aliases(input["aliases"]),
         :ok <- validate_student(%{display_name: display_name, line_user_id: input["line_user_id"]}) do
      parsed = %{
        "display_name" => display_name,
        "line_user_id" => blank_to_nil(input["line_user_id"]),
        "aliases" => aliases
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <-
           People.create_student(%{
             display_name: attrs["display_name"],
             line_user_id: attrs["line_user_id"]
           }),
         :ok <- add_aliases(student, attrs["aliases"] || []) do
      {:ok, {"Ganesha.People.Student", student.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    %{
      title: "#{label(:title, locale)} #{parsed["display_name"]}",
      lines:
        Enum.reject(
          [
            line(:line_user_id, parsed["line_user_id"], locale),
            aliases_line(parsed["aliases"], locale)
          ],
          &is_nil/1
        ),
      changes: [],
      web_path: nil
    }
  end

  defp require_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "", do: {:error, "display_name is required"}, else: {:ok, trimmed}
  end

  defp require_name(_name), do: {:error, "display_name is required"}

  defp normalize_aliases(nil), do: {:ok, []}

  defp normalize_aliases(aliases) when is_list(aliases) do
    cleaned =
      aliases
      |> Enum.map(&if(is_binary(&1), do: String.trim(&1), else: ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, cleaned}
  end

  defp normalize_aliases(_aliases), do: {:error, "aliases must be a list of strings"}

  defp validate_student(attrs) do
    case %People.Student{} |> People.change_student(attrs) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _student} -> :ok
      {:error, changeset} -> {:error, Assistant.format_changeset_errors(changeset)}
    end
  end

  defp add_aliases(_student, []), do: :ok

  defp add_aliases(student, [alias | rest]) do
    case People.add_alias(student, alias) do
      {:ok, _} -> add_aliases(student, rest)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp label(:title, "en"), do: "Add student"
  defp label(:title, _), do: "新增學生"
  defp label(:line_user_id, "en"), do: "LINE user id"
  defp label(:line_user_id, _), do: "LINE 使用者 id"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp aliases_line([], _locale), do: nil
  defp aliases_line(aliases, "en"), do: "Aliases: #{Enum.join(aliases, ", ")}"
  defp aliases_line(aliases, _locale), do: "別名：#{Enum.join(aliases, "、")}"
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/add_student_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/add_student.ex test/ganesha/assistant/tasks/add_student_test.exs
git commit -m "Add add_student LINE assistant task"
```

---

### Task 8: `save_package` task (spec §3.1 #20)

**Files:**
- Create: `lib/ganesha/assistant/tasks/save_package.ex`
- Test: `test/ganesha/assistant/tasks/save_package_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.Tasks.SavePackage` with `name/0` → `"save_package"`, `kind/0` → `:change`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tasks.SavePackageTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog}
  alias Ganesha.Assistant.Tasks.SavePackage

  test "creates a package" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}

    input = %{
      "name" => "晚間單堂",
      "kind" => "drop_in",
      "price_per_class" => 450,
      "included_makeups" => 0,
      "active" => true,
      "grandfather_strategy" => "none"
    }

    assert {:ok, %{parsed: parsed}} = SavePackage.propose(input, ctx)
    assert {:ok, {_, package_id}} = SavePackage.apply(parsed, "line:teacher")
    assert Catalog.get_package!(package_id).price_per_class == 450
  end

  test "edits a package and fails if it changed after propose" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}
    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    input = %{
      "package_id" => package.id,
      "price_per_class" => 420,
      "included_makeups" => 1,
      "active" => true,
      "grandfather_strategy" => "none"
    }

    assert {:ok, %{parsed: parsed}} = SavePackage.propose(input, ctx)
    {:ok, _} = Catalog.update_package(package, %{price_per_class: 500})
    assert {:error, :package_changed} = SavePackage.apply(parsed, "line:teacher")
  end
end

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/save_package_test.exs`
Expected: FAIL (module not defined)

- [ ] **Step 3: Implement the task module**

```elixir
defmodule Ganesha.Assistant.Tasks.SavePackage do
  @moduledoc """
  `save_package` (spec §3.1 #20): create or edit a catalog package through
  `Ganesha.Catalog.create_package/1` / `update_package/2`, as the settings
  screen does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Catalog}
  alias Ganesha.Assistant.Format
  alias Ganesha.Catalog.Package

  @create_keys ~w(name kind price_per_class included_makeups active grandfather_strategy)
  @update_keys ~w(package_id price_per_class included_makeups active grandfather_strategy)

  @impl true
  def name, do: "save_package"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Create a new package or edit an existing one on the price list. This only \
      proposes a Draft; the package is written when the teacher taps Confirm. \
      Omit package_id to create; pass package_id to edit price, makeup count, \
      active flag and grandfather strategy (name and kind are fixed after create).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          package_id: %{type: "integer", description: "Omit to create a new package"},
          name: %{type: "string"},
          kind: %{type: "string", enum: Package.kinds()},
          price_per_class: %{type: "integer", description: "NT$ per class"},
          included_makeups: %{type: "integer"},
          active: %{type: "boolean"},
          grandfather_strategy: %{type: "string", enum: Package.grandfather_strategies()}
        },
        required: ["price_per_class", "included_makeups", "active", "grandfather_strategy"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    case input["package_id"] do
      nil -> propose_create(input)
      id when is_integer(id) -> propose_update(id, input)
      _other -> {:error, "package_id must be an integer or omitted to create"}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    case parsed["mode"] do
      "create" -> apply_create(parsed)
      "update" -> apply_update(parsed)
      _other -> {:error, :invalid_mode}
    end
  end

  @impl true
  def describe(parsed, locale) do
    case parsed["mode"] do
      "create" -> describe_create(parsed, locale)
      "update" -> describe_update(parsed, locale)
    end
  end

  defp propose_create(input) do
    attrs = take_create(input)

    with :ok <- validate_package(attrs),
         :ok <- require_create_fields(attrs) do
      parsed =
        Map.merge(attrs, %{
          "mode" => "create",
          "name" => String.trim(attrs["name"] || ""),
          "active" => bool_field(input, "active", true),
          "grandfather_strategy" => attrs["grandfather_strategy"] || "none"
        })

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  defp propose_update(id, input) do
    with {:ok, package} <- fetch_package(id) do
      attrs = take_update(input, package)

      with :ok <- validate_update(package, attrs) do
        parsed =
          Map.merge(attrs, %{
            "mode" => "update",
            "package_id" => package.id,
            "name" => package.name,
            "kind" => package.kind,
            "before_price_per_class" => package.price_per_class,
            "before_included_makeups" => package.included_makeups,
            "before_active" => package.active,
            "before_grandfather_strategy" => package.grandfather_strategy
          })

        {:ok, %{student_id: nil, parsed: parsed}}
      end
    end
  end

  defp apply_create(parsed) do
    attrs = Map.take(parsed, @create_keys)

    with :ok <- fields_unchanged?(parsed, attrs),
         {:ok, package} <- Catalog.create_package(normalize_package_attrs(attrs)) do
      {:ok, {"Ganesha.Catalog.Package", package.id}}
    end
  end

  defp apply_update(parsed) do
    attrs = Map.take(parsed, @update_keys)

    with {:ok, package} <- load_package(attrs["package_id"]),
         :ok <- package_unchanged?(package, parsed),
         {:ok, updated} <-
           Catalog.update_package(package, %{
             price_per_class: attrs["price_per_class"],
             included_makeups: attrs["included_makeups"],
             active: attrs["active"],
             grandfather_strategy: attrs["grandfather_strategy"]
           }) do
      {:ok, {"Ganesha.Catalog.Package", updated.id}}
    end
  end

  defp describe_create(parsed, locale) do
    %{
      title: "#{label(:create, locale)} #{parsed["name"]}",
      lines:
        Enum.reject(
          [
            line(:kind, kind_name(parsed["kind"], locale), locale),
            line(:price, Format.money(parsed["price_per_class"]), locale),
            line(:makeups, "#{parsed["included_makeups"]}", locale),
            line(:active, bool_name(parsed["active"], locale), locale),
            line(:grandfather, grandfather_name(parsed["grandfather_strategy"], locale), locale)
          ],
          &is_nil/1
        ),
      changes: [],
      web_path: "/settings"
    }
  end

  defp describe_update(parsed, locale) do
    %{
      title: "#{label(:edit, locale)} #{parsed["name"]}",
      lines: [line(:kind, kind_name(parsed["kind"], locale), locale)],
      changes:
        Enum.reject(
          [
            change(:price, parsed["before_price_per_class"], parsed["price_per_class"], locale),
            change(:makeups, parsed["before_included_makeups"], parsed["included_makeups"], locale),
            change(:active, parsed["before_active"], parsed["active"], locale),
            change(
              :grandfather,
              parsed["before_grandfather_strategy"],
              parsed["grandfather_strategy"],
              locale
            )
          ],
          &is_nil/1
        ),
      web_path: "/settings"
    }
  end

  defp fetch_package(id) do
    case Catalog.get_package(id) do
      nil -> {:error, "no package with id #{id}"}
      package -> {:ok, package}
    end
  end

  defp load_package(id) do
    case Catalog.get_package(id) do
      nil -> {:error, :not_found}
      package -> {:ok, package}
    end
  end

  defp take_create(input) do
    %{
      "name" => input["name"],
      "kind" => input["kind"],
      "price_per_class" => input["price_per_class"],
      "included_makeups" => input["included_makeups"],
      "active" => bool_field(input, "active", true),
      "grandfather_strategy" => input["grandfather_strategy"] || "none"
    }
  end

  defp take_update(input, package) do
    %{
      "price_per_class" => input["price_per_class"] || package.price_per_class,
      "included_makeups" => input["included_makeups"] || package.included_makeups,
      "active" => bool_field(input, "active", package.active),
      "grandfather_strategy" => input["grandfather_strategy"] || package.grandfather_strategy
    }
  end

  defp bool_field(input, key, default) do
    case Map.get(input, key) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      nil -> default
      other -> other
    end
  end

  defp require_create_fields(%{"name" => name, "kind" => kind}) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed != "" and kind in Package.kinds(),
      do: :ok,
      else: {:error, "name and kind are required when creating a package"}
  end

  defp require_create_fields(_attrs),
    do: {:error, "name and kind are required when creating a package"}

  defp validate_package(attrs) do
    case %Package{} |> Package.changeset(normalize_package_attrs(attrs)) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, Assistant.format_changeset_errors(changeset)}
    end
  end

  defp validate_update(%Package{} = package, attrs) do
    case package
         |> Package.changeset(%{
           price_per_class: attrs["price_per_class"],
           included_makeups: attrs["included_makeups"],
           active: attrs["active"],
           grandfather_strategy: attrs["grandfather_strategy"]
         })
         |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, Assistant.format_changeset_errors(changeset)}
    end
  end

  defp normalize_package_attrs(attrs) do
    %{
      name: attrs["name"],
      kind: attrs["kind"],
      price_per_class: attrs["price_per_class"],
      included_makeups: attrs["included_makeups"],
      active: attrs["active"],
      grandfather_strategy: attrs["grandfather_strategy"]
    }
  end

  defp fields_unchanged?(parsed, attrs) do
    if Enum.all?(@create_keys, &(parsed[&1] == attrs[&1])), do: :ok, else: {:error, :package_changed}
  end

  defp package_unchanged?(package, parsed) do
    if package.price_per_class == parsed["before_price_per_class"] and
         package.included_makeups == parsed["before_included_makeups"] and
         package.active == parsed["before_active"] and
         package.grandfather_strategy == parsed["before_grandfather_strategy"],
       do: :ok,
       else: {:error, :package_changed}
  end

  defp label(:create, "en"), do: "New package"
  defp label(:create, _), do: "新增方案"
  defp label(:edit, "en"), do: "Edit package"
  defp label(:edit, _), do: "編輯方案"
  defp label(:kind, "en"), do: "Kind"
  defp label(:kind, _), do: "類型"
  defp label(:price, "en"), do: "Per class"
  defp label(:price, _), do: "每堂"
  defp label(:makeups, "en"), do: "Makeups included"
  defp label(:makeups, _), do: "補課次數"
  defp label(:active, "en"), do: "Open to new students"
  defp label(:active, _), do: "開放新學生"
  defp label(:grandfather, "en"), do: "When inactive"
  defp label(:grandfather, _), do: "停用後"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp change(:price, before, after_value, locale)
       when before != after_value,
       do: {label(:price, locale), Format.money(before), Format.money(after_value)}

  defp change(:makeups, before, after_value, locale) when before != after_value,
    do: {label(:makeups, locale), "#{before}", "#{after_value}"}

  defp change(:active, before, after_value, locale) when before != after_value,
    do: {label(:active, locale), bool_name(before, locale), bool_name(after_value, locale)}

  defp change(:grandfather, before, after_value, locale) when before != after_value,
    do:
      {label(:grandfather, locale), grandfather_name(before, locale),
       grandfather_name(after_value, locale)}

  defp change(_field, _before, _after, _locale), do: nil

  defp kind_name("monthly", "en"), do: "Monthly"
  defp kind_name("drop_in", "en"), do: "Drop-in"
  defp kind_name("trial", "en"), do: "Trial"
  defp kind_name("monthly", _), do: "月課程"
  defp kind_name("drop_in", _), do: "單堂"
  defp kind_name("trial", _), do: "體驗"
  defp kind_name(other, _), do: other

  defp bool_name(true, "en"), do: "Yes"
  defp bool_name(false, "en"), do: "No"
  defp bool_name(true, _), do: "是"
  defp bool_name(false, _), do: "否"
  defp bool_name(other, _), do: to_string(other)

  defp grandfather_name("none", "en"), do: "No renewals"
  defp grandfather_name("past_purchasers", "en"), do: "Past purchasers may renew"
  defp grandfather_name("none", _), do: "不可續購"
  defp grandfather_name("past_purchasers", _), do: "曾購買者可續購"
  defp grandfather_name(other, _), do: other
end

```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tasks/save_package_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/save_package.ex test/ganesha/assistant/tasks/save_package_test.exs
git commit -m "Add save_package LINE assistant task"
```

---

### Task 9: `Tasks` registry — Teacher chat only

**Files:**
- Modify: `lib/ganesha/assistant/tasks.ex`

**Interfaces:**
- Produces: `@teacher` includes all seven new modules; `Tasks.fetch("save_package")` works for each.

- [ ] **Step 1: Extend the alias list and `@teacher`**

Add to the existing `alias Ganesha.Assistant.Tasks.{...}` block (do not remove `RecordPayment`, `BookOneOff`, `MakeupRequest`, `AskTeacher`, `SetLanguage`):

```elixir
AddStudent,
BookMakeup,
ConfirmPayment,
Enroll,
OverridePrice,
SavePackage,
SetNoShow
```

Prepend the new change tasks to `@teacher` (slice 4 tasks first, then existing slice-1 tasks):

```elixir
@teacher [
  Enroll,
  RecordPayment,
  ConfirmPayment,
  OverridePrice,
  SetNoShow,
  BookMakeup,
  AddStudent,
  SavePackage,
  BookOneOff,
  MakeupRequest,
  AskTeacher,
  SetLanguage
]
```

`@group` and `@student` stay unchanged.

- [ ] **Step 2: Update `test/ganesha/assistant/tasks_test.exs`**

Replace the exact sorted `@teacher` equality with membership checks (keep the `:group` and `:student` assertions as-is):

```elixir
teacher = Tasks.for_chat(:teacher)
assert RecordPayment in teacher
assert Enroll in teacher
assert ConfirmPayment in teacher
assert OverridePrice in teacher
assert SetNoShow in teacher
assert BookMakeup in teacher
assert AddStudent in teacher
assert SavePackage in teacher
assert BookOneOff in teacher
assert MakeupRequest in teacher
assert AskTeacher in teacher
assert SetLanguage in teacher
```

- [ ] **Step 3: Run tests**

Run: `mix test test/ganesha/assistant/tasks_test.exs`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/ganesha/assistant/tasks.ex test/ganesha/assistant/tasks_test.exs
git commit -m "Register slice 4 student and money tasks for Teacher chat"
```

---

### Task 10: `mix precommit` and real Sonnet 5.5 — enroll + no-show

**Files:**
- Modify: `priv/scripts/line_real_turn.exs`

**Interfaces:**
- Consumes: slice 1 script; adds a second scenario selected by argv.
- Produces:
  - `source .env.dev && mix run priv/scripts/line_real_turn.exs enroll` — proposes an `enroll` Draft for a seeded student/slot/month.
  - `source .env.dev && mix run priv/scripts/line_real_turn.exs no_show` — proposes `set_no_show` on a seated attendance.

- [ ] **Step 1: Extend cleanup and fixtures**

After the existing `cleanup` function, also delete attendances, credits, slots/sessions for `SMOKE%` names, and `Studio.Slot` / `Studio.Session` rows created for the script (`display_name` like `SMOKE%` or fixed teacher id `Usmokerealturn00000000000000`).

Seed for **enroll**: `SMOKE 阿花`, active slot with `Studio.generate_month/2` for `2026-10`, monthly package `SMOKE 月課程`.

Seed for **no_show**: `SMOKE 阿花` already seated on one October session (via `Enrolling.add_one_off/4` or `enroll_month/1`); teacher message like `SMOKE 阿花 10/8 那堂沒來，幫我記缺席`.

Use `scenario = List.first(System.argv()) || "payment"` and branch: `"payment"` keeps the slice-1 default message and purchase owed; `"enroll"` / `"no_show"` use the seeds above and scenario-specific user text.

- [ ] **Step 2: Run `mix precommit`**

Run: `mix precommit`
Expected: clean compile, format, full test suite 0 failures.

- [ ] **Step 3: Real model runs**

Run:
```bash
mix ecto.migrate
source .env.dev && mix run priv/scripts/line_real_turn.exs enroll
source .env.dev && mix run priv/scripts/line_real_turn.exs no_show
```
Expected: each prints `== Drafts` with `kind: "enroll"` or `kind: "set_no_show"`, `state: "pending"`, and a Flex carousel with confirm/discard postbacks. Non-empty `choices` from the model is acceptable — re-run with a clearer message.

- [ ] **Step 4: Commit**

```bash
git add priv/scripts/line_real_turn.exs
git commit -m "Extend LINE real turn script for enroll and no-show"
```

---

## Decisions this plan makes where the spec is silent

- **`enroll` month input:** `YYYY-MM` string; omitted `session_ids` means all scheduled sessions of that slot in the month (matches enroll LiveView default checked boxes).
- **`enroll` inactive students:** rejected at `propose/2` (web dropdown uses active students only).
- **`confirm_payment`:** `payment_id` only; no new payment row (unlike `record_payment`).
- **`override_price`:** clearing override uses `custom_amount: null` in the tool schema; stored as `nil` in `parsed`.
- **`set_no_show`:** explicit `state` `no_show` | `expected`; proposing the current state is an error (toggle is never a no-op Draft).
- **`book_makeup`:** teacher must pass `credit_id` (model picks from `open_credits` / snapshot); apply checks consumption before roster membership.
- **`save_package` create:** `name` + `kind` required; **edit** does not change name/kind (settings UI only edits price, makeups, active, grandfather).
- **`save_package` stale check:** edits compare all four editable fields against `before_*` keys in `parsed`; creates compare full create attrs.
- **Registry order:** slice 4 tasks listed before slice 1 tasks in `@teacher` for readability; `Tasks.fetch/1` and `tool_schemas/1` are order-independent.
- **Real-turn script:** second CLI argument pattern uses the first argv token as scenario name instead of adding a separate flag.

## Verification record (plan author)

Applied this plan in a throwaway copy of branch `line-teacher-assistant` at `a1523b0` under `/tmp/plan-slice-4` (detached worktree + copied `_build`/`deps`). Result: `mix compile --warnings-as-errors` clean; `mix test test/ganesha/assistant/tasks/ test/ganesha/assistant/tasks_test.exs` — **76 tests, 0 failures**.
