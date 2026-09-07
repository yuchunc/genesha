# Monthly close — design

**Date:** 2026-09-07
**Status:** design, pending review
**Supersedes:** nothing — new capability on top of `docs/superpowers/specs/2026-09-06-ui-design-system.md`

## 1. Problem

`MoneyLive`'s `歷史款項` (history) list is entirely computed on demand: `previous_cycles/2`
walks backward from the current month, 12 at a time, calling `Reporting.revenue_for_month/1`
for every month regardless of whether anything happened that month. There is no floor —
pagination (`更早`) keeps producing pages of `NT$0` rows indefinitely, including months
before the studio had any data at all.

The fix: give a month a real, persisted record once it has actually ended, and only show
history rows for months that have one. This also gives the app's first genuine "closed
book" concept — a month's numbers, once closed, are a fact rather than a live query that
could shift if old data is edited.

## 2. Goals / non-goals

**Goals**
- `歷史款項` shows only months that have closed, with a natural pagination floor.
- A closed month's numbers are computed once, frozen, and reused — not recomputed on
  every page view.
- If a payment dated into an already-closed month is confirmed or corrected later, that
  month's frozen numbers refresh automatically (no amendment trail, no manual step).
- Closing happens without operator action, even though the app has no scheduler today.

**Non-goals**
- No backfill for months that already have data before this ships — not in production
  yet, so there is nothing to preserve.
- No amendment/audit trail distinguishing "originally closed" values from "refreshed"
  values beyond what `updated_at` already shows for free.
- No change to the 6-month trend chart or the current-cycle card — both intentionally
  keep including the current, still-open month and compute it live.
- No change to the underlying payment list in `MoneyLive.Cycle` — only the summary
  numbers at the top of a closed month's detail view change source.

## 3. Data model

New schema, `Ganesha.Reporting.MonthlyClose`, at `lib/ganesha/reporting/monthly_close.ex`
— `Reporting`'s first owned schema (today it only aggregates other contexts' data).

Table `monthly_closes`:

| field | type | notes |
|---|---|---|
| `month` | `:date` | always `Date.beginning_of_month/1`; unique index, one row per month |
| `revenue` | `:integer` | confirmed revenue for the month, frozen at close/refresh time |
| `revenue_by_method` | `:map` | `%{"line_pay" => 1600, "cash" => 0, ...}` — same shape as `revenue_by_method_for_month/1` today, persisted as JSON |
| `tax_threshold` | `:integer` | snapshot of `Reporting.monthly_threshold/0` as it was at close time — protects historical accuracy if the threshold changes in a future tax year |
| `inserted_at` / `updated_at` | `timestamps(type: :utc_datetime)` | standard; `updated_at` moving is the only trace of a post-close refresh |

`ratio` and `warn?` (the tax gauge fields) are **not** stored — they're pure derivations
of `revenue` and `tax_threshold`, computed the same way `tax_threshold_status/1` computes
them today, so there is no redundant value that can drift from its inputs.

`Reporting` context gains:

```elixir
@spec close_month(Date.t()) :: {:ok, MonthlyClose.t()}
def close_month(month)
# Computes revenue, revenue_by_method, and the current tax_threshold for `month`
# (via the existing live query functions) and upserts the MonthlyClose row for it.
# Idempotent: calling it again for the same month overwrites cleanly.

@spec get_closed_month(Date.t()) :: MonthlyClose.t() | nil
def get_closed_month(month)

@spec list_closed_months(before: Date.t(), limit: pos_integer()) :: [MonthlyClose.t()]
def list_closed_months(opts)
# Strictly-before `month`, most recent first, capped at `limit` — the query MoneyLive's
# history pagination needs, replacing previous_cycles/2's live loop.
```

`close_month/1` upserts via `Repo.insert(changeset, on_conflict: :replace_all,
conflict_target: :month)` — atomic, no window where the row is briefly absent.

## 4. Trigger

Adds `:oban` (latest stable, `~> 2.18` as of writing) with the SQLite engine:

```elixir
config :ganesha, Oban,
  engine: Oban.Engines.Lite,
  repo: Ganesha.Repo,
  queues: [default: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [{"10 16 * * *", Ganesha.Reporting.CloseMonthWorker}]}
  ]
```

`10 16 * * *` (UTC) is ~00:10 Taipei — matching how `Ganesha.Clock` already reasons about
the fixed UTC+8 offset elsewhere in this app. One-time Oban migration
(`Oban.Migration.up/1`) added alongside the `monthly_closes` migration. `Oban` added to
`Ganesha.Application`'s supervision tree.

**`Ganesha.Reporting.CloseMonthWorker`** (`lib/ganesha/reporting/close_month_worker.ex`):
runs daily, not precisely once at the boundary. `perform/1`: take `Clock.today()`, derive
the most recently *fully elapsed* month; if `Reporting.get_closed_month/1` is `nil` for
it, call `close_month/1`. Idempotent by construction — running it twice in a day, or
missing a day entirely (deploy downtime), is harmless; the next run just catches up. This
was chosen over a cron expression aimed at the exact month-boundary instant, which would
need to survive a single-instance Fly deploy landing at exactly the wrong second with zero
tolerance for a missed run.

**Refresh hook**: `Sales.confirm_payment/2` and the purchase-correction path, after
committing, check whether the affected payment's `paid_on` month already has a
`MonthlyClose` row; if so, call `Reporting.close_month/1` again to overwrite it. Plain
function call in the existing write path — not a job, synchronous with the request, same
as the rest of `Sales` today.

## 5. Read-path changes

- **`MoneyLive.previous_cycles/2`** → replaced by `Reporting.list_closed_months/1`,
  paginated the same way (12/page, strictly before the current month). Template is
  unchanged (`cycle.month`, `cycle.revenue`); `更早` produces an empty page once history
  runs out instead of an infinite wall of zeros.
- **`MoneyLive`'s 6-month trend chart (`chart_months/1`)** — unchanged, stays live. It's a
  fixed 6-bar window that always includes the current, open month, and a real `NT$0` bar
  for a quiet month is meaningful in a trend view. Only the paginated history list below
  it changes.
- **`MoneyLive.Cycle`** — for a month with a `MonthlyClose` row: reads `revenue` and
  `revenue_by_method` from it instead of recomputing. For the current, not-yet-closed
  month: keeps computing live, exactly as today. The payment list itself (本期收款) stays
  a live query in both cases — the snapshot only replaces the summary numbers at the top;
  individual payment rows are never frozen.

## 6. Error handling

- `close_month/1`'s upsert is a single atomic statement — no partial-write state.
- If `CloseMonthWorker` fails (transient DB error, etc.), Oban's default retry/backoff
  applies; failing that, tomorrow's scheduled run performs the same idempotent check and
  catches up. No manual intervention path needed for a single missed day.
- No user-facing error state: worst case, a month's close row appears a day late, which
  only affects how far back the history list's frozen data extends — never the
  current-cycle card or the current month's detail view, both of which are always live.

## 7. Testing

- `Reporting.close_month/1` — given payments across methods within a month, produces the
  correct frozen snapshot; calling it again after new data overwrites cleanly.
- `Reporting.list_closed_months/1` — pagination ordering and the `limit`/`before` bounds.
- `CloseMonthWorker` — via `Oban.Testing`'s `perform_job/2` (first Oban usage in this app,
  establishing the pattern): closes the correct month for a given `Clock.today()`, is a
  no-op when that month is already closed.
- Refresh hook — confirming a payment dated into an already-closed month updates that
  month's snapshot.
- `MoneyLive` — existing pagination test
  (`"pages into history without repeating the current cycle"`) updated to seed real
  `MonthlyClose` rows instead of relying on live computation; new test asserts `更早`
  shows nothing once rows run out.
- `MoneyLive.Cycle` — a closed month's summary reads from its frozen row (change
  underlying payment data after close, assert the displayed total doesn't move); the
  current month keeps behaving exactly as it does today.
