# Monthly Close Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `Ganesha.Reporting` a persisted, one-row-per-month "closed" snapshot so `MoneyLive`'s 歷史款項 list only shows months that actually happened, instead of an infinite computed wall of NT$0 rows.

**Architecture:** New `Ganesha.Reporting.MonthlyClose` schema (Reporting's first owned schema). A daily Oban cron job (`Ganesha.Reporting.CloseMonthWorker`, SQLite `Oban.Engines.Lite` engine) idempotently closes the most recently elapsed month if it isn't closed yet. `Sales.confirm_payment/2` refreshes an already-closed month's snapshot if a late confirmation lands in it. `MoneyLive`'s history list and `MoneyLive.Cycle`'s summary read the frozen snapshot when one exists, and fall back to today's live computation otherwise (covering the current, still-open month, and the brief window before a month's daily close job has run).

**Tech Stack:** Elixir/Phoenix/LiveView, Ecto + `ecto_sqlite3`, Oban (`Oban.Engines.Lite`).

**Spec:** `docs/superpowers/specs/2026-09-07-monthly-close-design.md`

## Global Constraints

- Oban engine is `Oban.Engines.Lite` (SQLite-backed), single node — matches this app's single Fly instance + Litestream setup.
- Cron schedule is exactly `"10 16 * * *"` (UTC) ≈ 00:10 Taipei — matches how `Ganesha.Clock` already reasons about the fixed UTC+8 offset elsewhere in this app.
- `CloseMonthWorker` runs daily and is idempotent (checks before writing) — not a precise once-a-month trigger. A missed run self-heals on the next day's run.
- No backfill for months that closed before this ships — not in production yet.
- No amendment/audit trail beyond the `updated_at` timestamp a refresh naturally bumps.
- The 6-month trend chart and the current-cycle card on `MoneyLive` stay live always — unaffected by this feature.
- The payment list inside `MoneyLive.Cycle` (本期收款) stays a live query always — only the summary numbers at the top (revenue, breakdown by method) swap source between live and frozen.
- `ratio` and `warn?` (tax gauge fields) are never stored — always derived from `revenue` and `tax_threshold`.

---

## Task 1: `MonthlyClose` schema and `Reporting` data-layer functions

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_monthly_closes.exs` (generate via `mix ecto.gen.migration create_monthly_closes`)
- Create: `lib/ganesha/reporting/monthly_close.ex`
- Modify: `lib/ganesha/reporting.ex`
- Test: `test/ganesha/reporting_test.exs`

**Interfaces:**
- Consumes: existing `Reporting.revenue_for_month/1`, `Reporting.revenue_by_method_for_month/1`, `@monthly_threshold` (all already in `lib/ganesha/reporting.ex`).
- Produces:
  - `Ganesha.Reporting.MonthlyClose` schema, fields `month :: Date.t()`, `revenue :: integer()`, `revenue_by_method :: map()`, `tax_threshold :: integer()`.
  - `Reporting.close_month(Date.t()) :: {:ok, MonthlyClose.t()}`
  - `Reporting.get_closed_month(Date.t()) :: MonthlyClose.t() | nil`
  - `Reporting.list_closed_months(before: Date.t(), limit: pos_integer(), offset: non_neg_integer()) :: [MonthlyClose.t()]`
  - `Reporting.cycle_summary(Date.t()) :: %{revenue: integer(), by_method: [{String.t(), integer()}]}`

- [ ] **Step 1: Write the failing tests**

Append to `test/ganesha/reporting_test.exs` (add `Reporting.MonthlyClose` to the top-level aliases already imported via `alias Ganesha.{Catalog, People, Reporting, Roster, Sales, Studio}` — no change needed there, `Reporting` is already aliased):

```elixir
  describe "close_month/1, get_closed_month/1, list_closed_months/1" do
    test "closes a month, freezing its revenue and per-method breakdown" do
      %{} = august_sale(1600)

      {:ok, closed} = Reporting.close_month(~D[2026-08-15])

      assert closed.month == ~D[2026-08-01]
      assert closed.revenue == 1600
      assert closed.revenue_by_method == %{"line_pay" => 1600, "line_bank" => 0, "cash" => 0, "other" => 0}
      assert closed.tax_threshold == Reporting.monthly_threshold()
      assert Reporting.get_closed_month(~D[2026-08-01]).id == closed.id
    end

    test "get_closed_month/1 is nil for a month that hasn't closed" do
      assert Reporting.get_closed_month(~D[2026-08-01]) == nil
    end

    test "close_month/1 overwrites cleanly when called again" do
      {:ok, _first} = Reporting.close_month(~D[2026-08-01])
      %{} = august_sale(1600)

      {:ok, second} = Reporting.close_month(~D[2026-08-01])

      assert second.revenue == 1600
      assert Reporting.list_closed_months(before: ~D[2026-09-01], limit: 12, offset: 0) == [second]
    end

    test "list_closed_months/1 is most-recent-first, strictly before the boundary, paginated" do
      {:ok, jun} = Reporting.close_month(~D[2026-06-01])
      {:ok, jul} = Reporting.close_month(~D[2026-07-01])
      {:ok, aug} = Reporting.close_month(~D[2026-08-01])

      assert Reporting.list_closed_months(before: ~D[2026-09-01], limit: 12, offset: 0) ==
               [aug, jul, jun]

      assert Reporting.list_closed_months(before: ~D[2026-08-01], limit: 12, offset: 0) ==
               [jul, jun]

      assert Reporting.list_closed_months(before: ~D[2026-09-01], limit: 1, offset: 1) == [jul]
    end
  end

  describe "cycle_summary/1" do
    test "reads live for a month that hasn't closed" do
      %{} = august_sale(1600)

      assert Reporting.cycle_summary(~D[2026-08-01]) == %{
               revenue: 1600,
               by_method: Reporting.revenue_by_method_for_month(~D[2026-08-01])
             }
    end

    test "reads the frozen snapshot for a month that has closed" do
      %{} = august_sale(1600)
      {:ok, _} = Reporting.close_month(~D[2026-08-01])

      assert Reporting.cycle_summary(~D[2026-08-01]) == %{
               revenue: 1600,
               by_method: [{"line_pay", 1600}, {"line_bank", 0}, {"cash", 0}, {"other", 0}]
             }
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/reporting_test.exs`
Expected: FAIL — `Reporting.close_month/1` (and friends) undefined.

- [ ] **Step 3: Generate and write the migration**

Run: `mix ecto.gen.migration create_monthly_closes`

Replace the generated file's `change/0` with:

```elixir
defmodule Ganesha.Repo.Migrations.CreateMonthlyCloses do
  use Ecto.Migration

  def change do
    create table(:monthly_closes) do
      # Always the 1st of the month. Frozen once written; a later
      # confirmation into this month overwrites the row rather than
      # creating a new one.
      add :month, :date, null: false
      add :revenue, :integer, null: false
      add :revenue_by_method, :map, null: false
      # The tax threshold as it was when this month closed, so a future
      # change to the tax law doesn't silently rewrite past history.
      add :tax_threshold, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:monthly_closes, [:month])
  end
end
```

- [ ] **Step 4: Write the schema**

Create `lib/ganesha/reporting/monthly_close.ex`:

```elixir
defmodule Ganesha.Reporting.MonthlyClose do
  @moduledoc """
  A month's confirmed revenue, frozen once that month has ended.

  One row per month. `revenue` and `revenue_by_method` are snapshots taken
  at close time (or refreshed by a later confirmation landing in an
  already-closed month) — never recomputed on read.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "monthly_closes" do
    field :month, :date
    field :revenue, :integer
    field :revenue_by_method, :map
    field :tax_threshold, :integer

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(monthly_close, attrs) do
    monthly_close
    |> cast(attrs, [:month, :revenue, :revenue_by_method, :tax_threshold])
    |> validate_required([:month, :revenue, :revenue_by_method, :tax_threshold])
    |> unique_constraint(:month)
  end
end
```

- [ ] **Step 5: Add the `Reporting` functions**

In `lib/ganesha/reporting.ex`, add `MonthlyClose` to the existing alias list (currently `alias Ganesha.Sales.{Payment, Purchase}` — add a line `alias Ganesha.Reporting.MonthlyClose` near the top with the other aliases), then refactor `revenue_by_method_for_month/1` to share a helper and add the four new functions. Replace the existing function (currently lines 98–113) with:

```elixir
  @spec revenue_by_method_for_month(Date.t()) :: [{String.t(), integer()}]
  def revenue_by_method_for_month(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Clock.end_of_month(month)

    totals =
      Repo.all(
        from pay in Payment,
          where: pay.state == "confirmed" and pay.paid_on >= ^first and pay.paid_on <= ^last,
          group_by: pay.method,
          select: {pay.method, sum(pay.amount)}
      )
      |> Map.new()

    ordered_methods(totals)
  end

  defp ordered_methods(totals) do
    for method <- Payment.methods(), do: {method, Map.get(totals, method, 0)}
  end

  @doc """
  Freezes a month's confirmed revenue, its breakdown by payment method, and
  the tax threshold in effect, into a permanent `MonthlyClose` row.

  Upserts — calling this again for an already-closed month overwrites it.
  That's how a payment confirmed after its month has closed refreshes the
  frozen snapshot.
  """
  @spec close_month(Date.t()) :: {:ok, MonthlyClose.t()}
  def close_month(%Date{} = month) do
    first = Date.beginning_of_month(month)

    attrs = %{
      month: first,
      revenue: revenue_for_month(first),
      revenue_by_method: Map.new(revenue_by_method_for_month(first)),
      tax_threshold: @monthly_threshold
    }

    %MonthlyClose{}
    |> MonthlyClose.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:revenue, :revenue_by_method, :tax_threshold, :updated_at]},
      conflict_target: :month
    )
  end

  @doc "The frozen snapshot for a month, or nil if it hasn't closed yet."
  @spec get_closed_month(Date.t()) :: MonthlyClose.t() | nil
  def get_closed_month(%Date{} = month) do
    Repo.get_by(MonthlyClose, month: Date.beginning_of_month(month))
  end

  @doc """
  Closed months strictly before `before`, most recent first — the page of
  history `MoneyLive`'s 歷史款項 list shows.
  """
  @spec list_closed_months(before: Date.t(), limit: pos_integer(), offset: non_neg_integer()) ::
          [MonthlyClose.t()]
  def list_closed_months(opts) do
    before = Keyword.fetch!(opts, :before)
    limit = Keyword.fetch!(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from c in MonthlyClose,
        where: c.month < ^Date.beginning_of_month(before),
        order_by: [desc: c.month],
        limit: ^limit,
        offset: ^offset
    )
  end

  @doc """
  A cycle's revenue and per-method breakdown — live for the current month
  or one that hasn't closed yet, frozen for one that has.
  """
  @spec cycle_summary(Date.t()) :: %{revenue: integer(), by_method: [{String.t(), integer()}]}
  def cycle_summary(%Date{} = month) do
    case get_closed_month(month) do
      nil ->
        %{revenue: revenue_for_month(month), by_method: revenue_by_method_for_month(month)}

      %MonthlyClose{} = closed ->
        %{revenue: closed.revenue, by_method: ordered_methods(closed.revenue_by_method)}
    end
  end
```

- [ ] **Step 6: Run migration and tests, verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/reporting_test.exs`
Expected: PASS

- [ ] **Step 7: Format and commit**

```bash
mix format
git add priv/repo/migrations lib/ganesha/reporting.ex lib/ganesha/reporting/monthly_close.ex test/ganesha/reporting_test.exs
git commit -m "feat: add MonthlyClose snapshot and Reporting close/read functions"
```

---

## Task 2: Oban and the daily `CloseMonthWorker`

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/prod.exs`
- Modify: `lib/ganesha/application.ex`
- Create: `priv/repo/migrations/<timestamp>_add_oban_jobs_table.exs` (generate via `mix ecto.gen.migration add_oban_jobs_table`)
- Create: `lib/ganesha/reporting/close_month_worker.ex`
- Test: `test/ganesha/reporting/close_month_worker_test.exs`

**Interfaces:**
- Consumes: `Reporting.close_month/1`, `Reporting.get_closed_month/1` (Task 1), `Ganesha.Clock.today/0`.
- Produces: `Ganesha.Reporting.CloseMonthWorker` (an `Oban.Worker`); Oban running in the supervision tree with the SQLite `Lite` engine, daily cron.

- [ ] **Step 1: Add the dependency**

In `mix.exs`, add to `deps/0` (next to the other Ecto deps):

```elixir
      {:oban, "~> 2.18"},
```

Run: `mix deps.get`

- [ ] **Step 2: Configure Oban across environments**

In `config/config.exs`, add (after the `config :ganesha, ecto_repos: ...` block):

```elixir
config :ganesha, Oban,
  repo: Ganesha.Repo,
  engine: Oban.Engines.Lite
```

In `config/dev.exs`, add:

```elixir
config :ganesha, Oban,
  queues: [default: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [{"10 16 * * *", Ganesha.Reporting.CloseMonthWorker}]}
  ]
```

In `config/prod.exs`, add the same block:

```elixir
config :ganesha, Oban,
  queues: [default: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [{"10 16 * * *", Ganesha.Reporting.CloseMonthWorker}]}
  ]
```

In `config/test.exs`, add (this fully disables automatic job processing so tests only run jobs explicitly via `Oban.Testing.perform_job/2`):

```elixir
config :ganesha, Oban, testing: :manual, queues: false, plugins: false
```

- [ ] **Step 3: Generate and write the Oban jobs-table migration**

Run: `mix ecto.gen.migration add_oban_jobs_table`

Replace the generated file's body with:

```elixir
defmodule Ganesha.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  defdelegate up, to: Oban.Migration
  defdelegate down, to: Oban.Migration
end
```

Run: `mix ecto.migrate`

- [ ] **Step 4: Start Oban in the supervision tree**

In `lib/ganesha/application.ex`, add `{Oban, Application.fetch_env!(:ganesha, Oban)}` to `children`, immediately after the `Ecto.Migrator` entry:

```elixir
    children = [
      GaneshaWeb.Telemetry,
      Ganesha.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ganesha, :ecto_repos), skip: skip_migrations?()},
      {Oban, Application.fetch_env!(:ganesha, Oban)},
      {DNSCluster, query: Application.get_env(:ganesha, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ganesha.PubSub},
      # Start a worker by calling: Ganesha.Worker.start_link(arg)
      # {Ganesha.Worker, arg},
      # Start to serve requests, typically the last entry
      GaneshaWeb.Endpoint
    ]
```

- [ ] **Step 5: Write the failing worker test**

Create `test/ganesha/reporting/close_month_worker_test.exs`:

```elixir
defmodule Ganesha.Reporting.CloseMonthWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo

  alias Ganesha.{Catalog, Clock, People, Reporting, Sales}
  alias Ganesha.Reporting.CloseMonthWorker

  defp last_month, do: Date.shift(Date.beginning_of_month(Clock.today()), month: -1)

  test "closes the most recently elapsed month" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: last_month()
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")

    assert :ok = perform_job(CloseMonthWorker, %{})

    closed = Reporting.get_closed_month(last_month())
    assert closed.revenue == 1600
  end

  test "is a no-op when the month is already closed" do
    {:ok, _} = Reporting.close_month(last_month())

    assert :ok = perform_job(CloseMonthWorker, %{})

    assert Reporting.get_closed_month(last_month()).revenue == 0
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/ganesha/reporting/close_month_worker_test.exs`
Expected: FAIL — `Ganesha.Reporting.CloseMonthWorker` undefined.

- [ ] **Step 7: Write the worker**

Create `lib/ganesha/reporting/close_month_worker.ex`:

```elixir
defmodule Ganesha.Reporting.CloseMonthWorker do
  @moduledoc """
  Closes the most recently elapsed month, if it isn't closed yet.

  Runs daily rather than exactly at the month boundary. Idempotent by
  construction: running it twice in a day, or missing a day entirely
  (deploy downtime), is harmless — the next run just catches up. No
  separate backfill/catch-up mechanism is needed.
  """
  use Oban.Worker, queue: :default

  alias Ganesha.Clock
  alias Ganesha.Reporting

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    last_month = Date.shift(Date.beginning_of_month(Clock.today()), month: -1)

    if is_nil(Reporting.get_closed_month(last_month)) do
      {:ok, _} = Reporting.close_month(last_month)
    end

    :ok
  end
end
```

- [ ] **Step 8: Run tests, verify they pass**

Run: `mix test test/ganesha/reporting/close_month_worker_test.exs`
Expected: PASS

- [ ] **Step 9: Format, full compile check, commit**

```bash
mix format
mix compile --warnings-as-errors
git add mix.exs mix.lock config/ lib/ganesha/application.ex priv/repo/migrations lib/ganesha/reporting/close_month_worker.ex test/ganesha/reporting/close_month_worker_test.exs
git commit -m "feat: add Oban and a daily CloseMonthWorker"
```

---

## Task 3: Refresh a closed month when a late payment is confirmed

**Files:**
- Modify: `lib/ganesha/sales.ex`
- Test: `test/ganesha/sales/payment_test.exs`

**Interfaces:**
- Consumes: `Reporting.close_month/1`, `Reporting.get_closed_month/1` (Task 1).
- Produces: `Sales.confirm_payment/2` — same signature and return shape (`{:ok, Payment.t()} | {:error, Ecto.Changeset.t()}`) as today; callers (`MoneyLive.Cycle`, `StudentLive.Show`) need no changes.

- [ ] **Step 1: Write the failing test**

In `test/ganesha/sales/payment_test.exs`, add `Reporting` to the module's alias line (`alias Ganesha.{Catalog, Clock, People, Reporting, Sales}`), then add:

```elixir
  test "confirming a payment refreshes an already-closed month" do
    purchase = purchase_fixture()
    past_month = Date.shift(Date.beginning_of_month(Clock.today()), month: -2)

    {:ok, _} = Reporting.close_month(past_month)
    assert Reporting.get_closed_month(past_month).revenue == 0

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: past_month
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")

    assert Reporting.get_closed_month(past_month).revenue == 1600
  end

  test "confirming a payment in a month that hasn't closed does not create a close row" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: Clock.today()
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")

    assert Reporting.get_closed_month(Clock.today()) == nil
  end
```

- [ ] **Step 2: Run tests to verify the first one fails**

Run: `mix test test/ganesha/sales/payment_test.exs`
Expected: FAIL on "confirming a payment refreshes an already-closed month" — revenue stays `0`.

- [ ] **Step 3: Add the refresh hook**

In `lib/ganesha/sales.ex`, add `alias Ganesha.Reporting` to the top-level aliases, then replace `confirm_payment/2` (currently):

```elixir
  def confirm_payment(%Payment{} = payment, confirmed_by) do
    payment |> Payment.confirmation_changeset(confirmed_by) |> Repo.update()
  end
```

with:

```elixir
  @doc """
  The only path to a confirmed payment. If the payment's month has already
  closed, refreshes that month's frozen snapshot to include it — a payment
  confirmed while its month is still open is picked up whenever that month
  eventually closes, so no refresh is needed there.
  """
  def confirm_payment(%Payment{} = payment, confirmed_by) do
    with {:ok, confirmed} <-
           payment |> Payment.confirmation_changeset(confirmed_by) |> Repo.update() do
      refresh_closed_month(confirmed.paid_on)
      {:ok, confirmed}
    end
  end

  defp refresh_closed_month(paid_on) do
    month = Date.beginning_of_month(paid_on)

    if Reporting.get_closed_month(month) do
      {:ok, _} = Reporting.close_month(month)
    end
  end
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `mix test test/ganesha/sales/payment_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/ganesha/sales.ex test/ganesha/sales/payment_test.exs
git commit -m "feat: refresh a closed month when a late payment is confirmed"
```

---

## Task 4: `MoneyLive` history list reads closed months

**Files:**
- Modify: `lib/ganesha_web/live/money_live.ex`
- Test: `test/ganesha_web/live/money_live_test.exs`

**Interfaces:**
- Consumes: `Reporting.list_closed_months/1` (Task 1).
- Produces: `MoneyLive`'s 歷史款項 section shows only closed months, plus an empty state `#no-history` when there are none.

- [ ] **Step 1: Write the failing tests**

In `test/ganesha_web/live/money_live_test.exs`, add `Reporting` to the module's alias line (`alias Ganesha.{Catalog, Clock, People, Reporting, Sales}`), then add:

```elixir
  test "shows a closed month's frozen revenue in history", %{conn: conn} do
    past_month = Date.shift(Date.beginning_of_month(Clock.today()), month: -1)
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: past_month
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    {:ok, _} = Reporting.close_month(past_month)

    {:ok, view, _html} = live(conn, ~p"/money")

    assert has_element?(view, "#cycle-#{past_month.year}-#{past_month.month}")
    html = view |> element("#cycle-#{past_month.year}-#{past_month.month}") |> render()
    assert html =~ "1,600"
  end

  test "history shows nothing when no month has closed yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#no-history")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha_web/live/money_live_test.exs`
Expected: FAIL — neither `#cycle-...` nor `#no-history` render yet (the current implementation always synthesizes 12 zero-revenue rows and never shows an empty state).

- [ ] **Step 3: Swap `previous_cycles/2` to the closed-month query**

In `lib/ganesha_web/live/money_live.ex`, replace (currently):

```elixir
  # A page of history, strictly before the current cycle — which already has
  # its own card above and would be a redundant first row here.
  defp previous_cycles(current_month, page) do
    first_offset = 1 + page * @cycles_per_page

    for offset <- first_offset..(first_offset + @cycles_per_page - 1) do
      month = Date.shift(current_month, month: -offset)
      %{month: month, revenue: Reporting.revenue_for_month(month)}
    end
  end
```

with:

```elixir
  # A page of history, strictly before the current cycle — which already has
  # its own card above and would be a redundant first row here. Only months
  # that have actually closed appear; there is no synthetic zero-revenue
  # filler for months before the studio had any data.
  defp previous_cycles(current_month, page) do
    Reporting.list_closed_months(
      before: current_month,
      limit: @cycles_per_page,
      offset: page * @cycles_per_page
    )
  end
```

- [ ] **Step 4: Add the empty state to the template**

In the same file's `render/1`, inside the `歷史款項` `<.section>` (currently ending with the `<ul>...</ul>` block), add an `<.empty>` row after the `</ul>`:

```heex
      <.section title="歷史款項">
        <:actions>
          <.button
            :if={@page > 0}
            variant="quiet"
            patch={~p"/money?#{[page: @page - 1]}"}
          >
            較近
          </.button>
          <.button variant="quiet" patch={~p"/money?#{[page: @page + 1]}"}>更早</.button>
        </:actions>

        <ul class="space-y-1">
          <li
            :for={cycle <- @cycles}
            id={"cycle-#{cycle.month.year}-#{cycle.month.month}"}
            class="border-l-[3px] border-rule"
          >
            <.link
              navigate={~p"/money/#{cycle.month.year}/#{cycle.month.month}"}
              class="flex min-h-11 items-center justify-between gap-4 py-1.5 pl-4 transition-colors hover:bg-sunk"
            >
              <span class="font-display text-base text-ink">{Fmt.month_title(cycle.month)}</span>
              <.money amount={cycle.revenue} size="sm" class="shrink-0" />
            </.link>
          </li>
        </ul>

        <.empty :if={@cycles == []} id="no-history">尚無歷史紀錄。</.empty>
      </.section>
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `mix test test/ganesha_web/live/money_live_test.exs`
Expected: PASS (all tests in the file, including the pre-existing pagination test, which asserts only on pagination controls and is unaffected by this change).

- [ ] **Step 6: Format and commit**

```bash
mix format
git add lib/ganesha_web/live/money_live.ex test/ganesha_web/live/money_live_test.exs
git commit -m "feat: MoneyLive history list reads closed months only"
```

---

## Task 5: `MoneyLive.Cycle` reads the frozen summary for closed months

**Files:**
- Modify: `lib/ganesha_web/live/money_live/cycle.ex`
- Test: `test/ganesha_web/live/money_live/cycle_test.exs`

**Interfaces:**
- Consumes: `Reporting.cycle_summary/1` (Task 1).
- Produces: `MoneyLive.Cycle`'s `#cycle-revenue` and 收款方式 breakdown read from the frozen snapshot once a month has closed; unchanged (live) otherwise. `本期收款` payment list is untouched.

- [ ] **Step 1: Write the failing test**

In `test/ganesha_web/live/money_live/cycle_test.exs`, add `Reporting` to the module's alias line (`alias Ganesha.{Catalog, People, Repo, Reporting, Sales}`), then add:

```elixir
  test "a closed month reads its frozen snapshot instead of recomputing live", %{conn: conn} do
    %{purchase: purchase} = student_with_purchase()
    past_month = ~D[2026-07-01]

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: past_month
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    {:ok, closed} = Reporting.close_month(past_month)

    # Overwrite the frozen row directly, bypassing what live computation
    # would currently produce, to prove the detail view reads the snapshot
    # rather than recomputing it on every visit.
    closed |> Ecto.Changeset.change(revenue: 9999) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/money/2026/7")

    assert has_element?(view, "#cycle-revenue[data-amount='9999']")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha_web/live/money_live/cycle_test.exs`
Expected: FAIL — `#cycle-revenue` shows `1600` (live-recomputed), not `9999`.

- [ ] **Step 3: Swap `load/1` to use `cycle_summary/1`**

In `lib/ganesha_web/live/money_live/cycle.ex`, replace (currently):

```elixir
  defp load(socket) do
    month = socket.assigns.month

    socket
    |> assign(:revenue, Reporting.revenue_for_month(month))
    |> assign(
      :by_method,
      Enum.reject(Reporting.revenue_by_method_for_month(month), &match?({_, 0}, &1))
    )
    |> assign(:payments, payments_with_flags(month))
  end
```

with:

```elixir
  defp load(socket) do
    month = socket.assigns.month
    summary = Reporting.cycle_summary(month)

    socket
    |> assign(:revenue, summary.revenue)
    |> assign(:by_method, Enum.reject(summary.by_method, &match?({_, 0}, &1)))
    |> assign(:payments, payments_with_flags(month))
  end
```

- [ ] **Step 4: Run test, verify it passes**

Run: `mix test test/ganesha_web/live/money_live/cycle_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/ganesha_web/live/money_live/cycle.ex test/ganesha_web/live/money_live/cycle_test.exs
git commit -m "feat: MoneyLive.Cycle reads the frozen summary for closed months"
```

- [ ] **Step 6: Full verification**

Run: `mix precommit`
Expected: PASS, zero warnings, no unexpected `git status` changes beyond this feature's files.

Manually verify in the browser: start `mix phx.server`, seed a closed month via `mix run -e 'Ganesha.Reporting.close_month(~D[2026-08-01])'` (after seeding a confirmed August payment), visit `/money`, confirm the closed month appears in 歷史款項 and its detail view at `/money/2026/8` shows the same numbers. Clean up any manually-seeded dev data afterward.
