# Studio Ledger Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a teacher-only, phone-first Phoenix app that replaces a solo yoga studio's hand-maintained class/payment document — price list, schedule, rosters, makeup credits, payments, reporting, and the monthly LINE announcement.

**Architecture:** Seven modules of domain logic (`Catalog`, `People`, `Studio`, `Sales`, `Roster`, `Reporting`, `Publishing`) behind LiveView screens. A *purchase* is the money side of a sale; an *attendance* row is the roster. Makeup entitlements are `Credit` rows held by the student, portable across weekday slots. Payments are claims that only a human may confirm. No LINE integration in this plan.

**Tech Stack:** Elixir ~> 1.17, Phoenix 1.8.13, LiveView 1.2, Ecto + `ecto_sqlite3`, Bandit, Tailwind v4, `:req`. Deployed on Fly.io with Litestream replication.

**Spec:** `docs/superpowers/specs/2026-09-03-yoga-studio-ledger-design.md`

## Global Constraints

- **Money is integer TWD.** No floats, no `Decimal`. `payments.amount` is `NOT NULL`.
- **No `month` column anywhere.** A purchase's period is derived from the dates of its attendance rows.
- **`payment.state = "confirmed"` may never be written by code.** Only a human action sets it, always with `confirmed_at` and `confirmed_by`.
- **`payment.amount` is the portion applied to that purchase**, not the bank transaction total. Payment rows do not map 1:1 onto bank lines.
- **Dates are Taipei dates.** Taiwan has no DST; UTC+8 is a fixed offset. Always use `Ganesha.Clock.today/0`, never `Date.utc_today/0`.
- **SQLite cannot `ALTER TABLE ADD CONSTRAINT`** — its `ALTER TABLE` supports only RENAME/ADD COLUMN/DROP COLUMN, so `Ecto.Migration.constraint/3` is unavailable. Enforce invariants in changesets; use unique and *partial* unique indexes (which SQLite does support) for database-level guarantees.
- **No daisyUI.** `AGENTS.md` requires hand-written Tailwind components. Do not reintroduce the dependency.
- **No inline `<script>` in HEEx.** Use `Phoenix.LiveView.ColocatedHook`, whose name must start with a dot.
- **UI copy is Traditional Chinese.** Code, identifiers, comments, and commit messages are English.
- **Phone-first.** Tap targets ≥44px, cards not tables, `push_patch`/`navigate` rather than modals.
- **LiveView collections use streams** with `phx-update="stream"` on the parent and a DOM id per child.
- **Every LiveView template begins with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.**
- Run `mix precommit` before the final commit of each task.

---

### Task 1: Foundation — strip daisyUI, add the Taipei clock

**Files:**
- Modify: `mix.exs` (remove the daisyUI dep block at lines 61-67)
- Modify: `assets/css/app.css` (subtract the daisyUI plugins only — see Step 2)
- Modify: `lib/ganesha_web/components/core_components.ex` (replace daisyUI `btn`/`toast` classes)
- Create: `lib/ganesha/clock.ex`
- Test: `test/ganesha/clock_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Ganesha.Clock.today() :: Date.t()`, `Ganesha.Clock.now() :: DateTime.t()` (UTC), `Ganesha.Clock.to_taipei_date(DateTime.t()) :: Date.t()`, `Ganesha.Clock.end_of_month(Date.t()) :: Date.t()`.

- [ ] **Step 1: Remove the daisyUI dependency**

Delete this block from `mix.exs`:

```elixir
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
```

Then run `mix deps.unlock daisyui && mix deps.clean daisyui`.

- [ ] **Step 2: Subtract the daisyUI plugins from `app.css` — and nothing else**

This is a deletion of three blocks, **not** a replacement of the file. Delete only:

```css
@plugin "daisyui/packages/bundle/daisyui" { themes: false; }
@plugin "daisyui/packages/bundle/daisyui-theme" { name: "dark"; ... }
@plugin "daisyui/packages/bundle/daisyui-theme" { name: "light"; ... }
```

Every other line stays verbatim. These five in particular are load-bearing and unrelated
to daisyUI — removing any of them breaks the app while leaving all tests green:

| Line | Why it must survive |
|---|---|
| `@plugin "../vendor/heroicons";` | `core_components.ex` renders `<.icon>` as `<span class={[@name, @class]}>`, so `hero-x-mark` is *only* a CSS class. Without the plugin every icon is an invisible empty span. `heroicons` stays a `mix.exs` dep. |
| `@import "phoenix-colocated/ganesha/colocated.css";` + `@source "../../_build/dev/phoenix-colocated/ganesha/*/";` | Colocated asset pickup. `assets/js/app.js` imports `phoenix-colocated/ganesha`, and Global Constraints mandate `ColocatedHook` for all JS. |
| `@custom-variant phx-click-loading` / `phx-submit-loading` / `phx-change-loading` | LiveView loading-state styling on buttons and forms. |
| `@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *));` | `layouts/root.html.heex` sets `data-theme` on `<html>`. Without this variant every `dark:` class in this plan's screens keys off `prefers-color-scheme` instead, and the app's own theme toggle stops working. |
| `[data-phx-session], [data-phx-teleported-src] { display: contents }` | Keeps LiveView wrapper divs transparent to layout; without it they become flex/grid participants and the phone layouts break. |

Verify the plugin actually still emits classes rather than trusting the file text: after
the asset build, grep the built stylesheet for `.hero-` and confirm a non-zero count.

- [ ] **Step 2b: Replace daisyUI classes in `core_components.ex`**

Removing the framework while its class names still ship is an incomplete removal, and no
later task touches this file. Two components carry daisyUI classes:

- `<.button>` uses `btn` and its variants
- `<.flash>` uses `toast` and its variants

Swap them for hand-written Tailwind. Keep each component's attrs, slots, and call sites
unchanged — this is styling only. Buttons keep a ≥44px tap target (phone-first).

Do **not** touch `layouts.ex` or `page_html/home.html.heex`: Task 12 rewrites the first
and deletes the second, so their daisyUI classes resolve themselves.

- [ ] **Step 3: Write the failing clock test**

`test/ganesha/clock_test.exs`:

```elixir
defmodule Ganesha.ClockTest do
  use ExUnit.Case, async: true
  alias Ganesha.Clock

  test "to_taipei_date/1 rolls over before UTC midnight" do
    # 17:00 UTC on 8/31 is already 01:00 on 9/1 in Taipei (UTC+8).
    assert Clock.to_taipei_date(~U[2026-08-31 17:00:00Z]) == ~D[2026-09-01]
  end

  test "to_taipei_date/1 keeps the same date early in the UTC day" do
    assert Clock.to_taipei_date(~U[2026-08-31 03:00:00Z]) == ~D[2026-08-31]
  end

  test "today/0 is either the UTC date or the day after" do
    assert Clock.today() in [Date.utc_today(), Date.add(Date.utc_today(), 1)]
  end

  test "end_of_month/1 returns the last day of that month" do
    assert Clock.end_of_month(~D[2026-08-17]) == ~D[2026-08-31]
    assert Clock.end_of_month(~D[2026-02-03]) == ~D[2026-02-28]
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `mix test test/ganesha/clock_test.exs`
Expected: FAIL — `Ganesha.Clock.to_taipei_date/1 is undefined`.

- [ ] **Step 5: Implement the clock**

`lib/ganesha/clock.ex`:

```elixir
defmodule Ganesha.Clock do
  @moduledoc """
  Taipei-local dates.

  Taiwan observes no daylight saving time, so UTC+8 is a fixed offset. Using a
  fixed offset avoids adding a timezone database dependency (`DateTime.now!/2`
  would require one) and is exact for this locale.

  Every date shown to the user, and every date used in a business rule —
  notably credit expiry — MUST come from here rather than `Date.utc_today/0`.
  Expiring a credit on a UTC month boundary would kill it eight hours early.
  """

  @offset_seconds 8 * 60 * 60

  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  @spec today() :: Date.t()
  def today, do: to_taipei_date(now())

  @spec to_taipei_date(DateTime.t()) :: Date.t()
  def to_taipei_date(%DateTime{} = utc) do
    utc |> DateTime.add(@offset_seconds, :second) |> DateTime.to_date()
  end

  @spec end_of_month(Date.t()) :: Date.t()
  def end_of_month(%Date{} = date), do: Date.end_of_month(date)
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/ganesha/clock_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 7: Verify the app still builds without daisyUI**

Run: `mix deps.get && mix assets.build && mix compile --warnings-as-errors`
Expected: no errors and no reference to daisyui.

- [ ] **Step 8: Commit**

```bash
git add mix.exs mix.lock assets/css/app.css lib/ganesha/clock.ex test/ganesha/clock_test.exs
git commit -m "feat: remove daisyUI and add Taipei-local clock"
```

---

### Task 2: Authentication — single teacher, registration closed

**Files:**
- Create (generated): `lib/ganesha/accounts.ex`, `lib/ganesha/accounts/*`, `lib/ganesha_web/live/user_live/*`, `lib/ganesha_web/user_auth.ex`
- Modify: `lib/ganesha_web/router.ex`
- Modify: `priv/repo/seeds.exs`
- Test: `test/ganesha_web/registration_closed_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `@current_scope` assign on authenticated LiveViews; `GaneshaWeb.UserAuth.on_mount/4`; an authenticated `live_session`; `register_and_log_in_user/1` test helper used by every later LiveView test.

- [ ] **Step 1: Run the auth generator**

```bash
mix phx.gen.auth Accounts User users --live
mix deps.get
mix ecto.migrate
```

- [ ] **Step 2: Locate the registration routes**

Run: `grep -n "Registration\|live_session\|require_authenticated" lib/ganesha_web/router.ex`

Record the exact route lines mentioning `UserLive.Registration` and the name of the authenticated `live_session` block — later tasks add routes inside it.

- [ ] **Step 3: Write the failing test that registration is unreachable**

`test/ganesha_web/registration_closed_test.exs`:

```elixir
defmodule GaneshaWeb.RegistrationClosedTest do
  use GaneshaWeb.ConnCase, async: true

  test "the registration page does not exist", %{conn: conn} do
    assert_raise Phoenix.Router.NoRouteError, fn ->
      get(conn, ~p"/users/register")
    end
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `mix test test/ganesha_web/registration_closed_test.exs`
Expected: FAIL — the route still exists, so no error is raised.

- [ ] **Step 5: Delete the registration route and LiveView**

Remove every route mentioning `UserLive.Registration` from `lib/ganesha_web/router.ex`, then:

```bash
rm -f lib/ganesha_web/live/user_live/registration.ex
rm -f test/ganesha_web/live/user_live/registration_test.exs
```

Leave login, session, and settings routes and tests intact.

- [ ] **Step 6: Run the test to verify it passes**

Run: `mix test test/ganesha_web/registration_closed_test.exs`
Expected: PASS.

- [ ] **Step 7: Seed the teacher account**

Append to `priv/repo/seeds.exs`:

```elixir
# The studio has exactly one user and registration is closed, so the account
# is seeded here. Override with TEACHER_EMAIL / TEACHER_PASSWORD.
teacher_email = System.get_env("TEACHER_EMAIL") || "teacher@example.com"
teacher_password = System.get_env("TEACHER_PASSWORD") || "change-me-please-1234"

case Ganesha.Accounts.get_user_by_email(teacher_email) do
  nil ->
    {:ok, _user} =
      Ganesha.Accounts.register_user(%{email: teacher_email, password: teacher_password})

    IO.puts("Seeded teacher account: #{teacher_email}")

  _user ->
    IO.puts("Teacher account already present: #{teacher_email}")
end
```

If the generated context uses different function names, run
`grep -n "def register_user\|def get_user_by_email" lib/ganesha/accounts.ex` and use the actual ones.

- [ ] **Step 8: Reset, seed, and run the suite**

Run: `mix ecto.reset && mix test`
Expected: the seed prints the teacher email; all tests pass.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: add single-teacher auth with registration closed"
```

---

### Task 3: Catalog — the price list

**Files:**
- Create: `lib/ganesha/catalog.ex`, `lib/ganesha/catalog/package.ex`
- Create: `priv/repo/migrations/<timestamp>_create_packages.exs`
- Modify: `priv/repo/seeds.exs`
- Test: `test/ganesha/catalog_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `%Ganesha.Catalog.Package{name, kind, price_per_class, included_makeups, active}` with `kind` in `"monthly" | "drop_in" | "trial"`; `Catalog.list_packages/0`, `Catalog.list_active_packages/0`, `Catalog.get_package!/1`, `Catalog.create_package/1`, `Catalog.update_package/2`, `Catalog.change_package/2`, `Catalog.price_for(package, session_count) :: integer`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_packages
```

```elixir
defmodule Ganesha.Repo.Migrations.CreatePackages do
  use Ecto.Migration

  def change do
    create table(:packages) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :price_per_class, :integer, null: false
      # How many makeup credits a purchase of this package grants. 1 for the
      # monthly package, 0 for drop-in and trial. Policy lives in data.
      add :included_makeups, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:packages, [:name])
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/catalog_test.exs`:

```elixir
defmodule Ganesha.CatalogTest do
  use Ganesha.DataCase
  alias Ganesha.Catalog
  alias Ganesha.Catalog.Package

  test "creates a monthly package granting one makeup" do
    assert {:ok, pkg} =
             Catalog.create_package(%{
               name: "月課程",
               kind: "monthly",
               price_per_class: 400,
               included_makeups: 1
             })

    assert pkg.kind == "monthly"
    assert pkg.included_makeups == 1
    assert pkg.active
  end

  test "defaults included_makeups to zero" do
    assert {:ok, pkg} =
             Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    assert pkg.included_makeups == 0
  end

  test "rejects an unknown kind" do
    assert {:error, cs} =
             Catalog.create_package(%{name: "x", kind: "weekly", price_per_class: 1})

    assert "is invalid" in errors_on(cs).kind
  end

  test "rejects a negative price" do
    assert {:error, cs} =
             Catalog.create_package(%{name: "x", kind: "trial", price_per_class: -1})

    assert "must be greater than or equal to 0" in errors_on(cs).price_per_class
  end

  test "package names are unique" do
    {:ok, _} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    assert {:error, cs} =
             Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    assert "has already been taken" in errors_on(cs).name
  end

  describe "price_for/2 — the numbers from the August document" do
    test "monthly package at 400 per class" do
      pkg = %Package{price_per_class: 400}
      assert Catalog.price_for(pkg, 4) == 1600
      assert Catalog.price_for(pkg, 3) == 1200
      # 彩華's two classes at the package rate.
      assert Catalog.price_for(pkg, 2) == 800
    end

    test "drop-in at 450 per class" do
      pkg = %Package{price_per_class: 450}
      assert Catalog.price_for(pkg, 1) == 450
      # 素容's two classes at the drop-in rate.
      assert Catalog.price_for(pkg, 2) == 900
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/catalog_test.exs`
Expected: FAIL — `Ganesha.Catalog` is undefined.

- [ ] **Step 4: Implement the schema**

`lib/ganesha/catalog/package.ex`:

```elixir
defmodule Ganesha.Catalog.Package do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(monthly drop_in trial)

  schema "packages" do
    field :name, :string
    field :kind, :string
    field :price_per_class, :integer
    field :included_makeups, :integer, default: 0
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(package, attrs) do
    package
    |> cast(attrs, [:name, :kind, :price_per_class, :included_makeups, :active])
    |> validate_required([:name, :kind, :price_per_class])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:price_per_class, greater_than_or_equal_to: 0)
    |> validate_number(:included_makeups, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
```

- [ ] **Step 5: Implement the context**

`lib/ganesha/catalog.ex`:

```elixir
defmodule Ganesha.Catalog do
  @moduledoc "The studio's price list."

  import Ecto.Query, warn: false
  alias Ganesha.Catalog.Package
  alias Ganesha.Repo

  def list_packages do
    Repo.all(from p in Package, order_by: [desc: p.active, asc: p.name])
  end

  def list_active_packages do
    Repo.all(from p in Package, where: p.active, order_by: p.name)
  end

  def get_package!(id), do: Repo.get!(Package, id)

  def create_package(attrs) do
    %Package{} |> Package.changeset(attrs) |> Repo.insert()
  end

  def update_package(%Package{} = package, attrs) do
    package |> Package.changeset(attrs) |> Repo.update()
  end

  def change_package(%Package{} = package, attrs \\ %{}) do
    Package.changeset(package, attrs)
  end

  @doc """
  The list price for buying `session_count` classes of this package.

  A suggestion only. The agreed number is snapshotted onto the purchase as
  `list_price`, and may be overridden there by `custom_amount`.
  """
  @spec price_for(Package.t() | map(), non_neg_integer()) :: integer()
  def price_for(%{price_per_class: per_class}, session_count)
      when is_integer(session_count) and session_count >= 0 do
    per_class * session_count
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/catalog_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 7: Seed the three real packages**

Append to `priv/repo/seeds.exs`:

```elixir
for attrs <- [
      %{name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1},
      %{name: "單堂", kind: "drop_in", price_per_class: 450, included_makeups: 0},
      %{name: "體驗", kind: "trial", price_per_class: 450, included_makeups: 0}
    ] do
  case Ganesha.Repo.get_by(Ganesha.Catalog.Package, name: attrs.name) do
    nil -> {:ok, _} = Ganesha.Catalog.create_package(attrs)
    _existing -> :ok
  end
end
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add catalog with seeded price list"
```

---

### Task 4: People — students and their aliases

**Files:**
- Create: `lib/ganesha/people.ex`, `lib/ganesha/people/student.ex`, `lib/ganesha/people/student_alias.ex`
- Create: `priv/repo/migrations/<timestamp>_create_students.exs`
- Test: `test/ganesha/people_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `%Ganesha.People.Student{display_name, line_user_id, active}`; `People.list_students/0`, `People.list_active_students/0`, `People.get_student!/1`, `People.create_student/1`, `People.update_student/2`, `People.change_student/2`, `People.add_alias/2`, `People.find_by_alias/1`, `People.find_by_line_user_id/1`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_students
```

```elixir
defmodule Ganesha.Repo.Migrations.CreateStudents do
  use Ecto.Migration

  def change do
    create table(:students) do
      add :display_name, :string, null: false
      # Nullable: a cash-only student may never appear in LINE. Unique because
      # a LINE user id is stable for the life of the account, and is the key we
      # match on once known. Display names change freely and are never the key.
      add :line_user_id, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:students, [:line_user_id])

    create table(:student_aliases) do
      add :student_id, references(:students, on_delete: :delete_all), null: false
      add :alias, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # An alias must identify exactly one student, or the phase-2 parser cannot
    # use it to attribute a message.
    create unique_index(:student_aliases, [:alias])
    create index(:student_aliases, [:student_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/people_test.exs`:

```elixir
defmodule Ganesha.PeopleTest do
  use Ganesha.DataCase
  alias Ganesha.People

  test "creates a student with only a display name" do
    assert {:ok, student} = People.create_student(%{display_name: "Lulu"})
    assert student.active
    assert is_nil(student.line_user_id)
  end

  test "requires a display name" do
    assert {:error, cs} = People.create_student(%{})
    assert "can't be blank" in errors_on(cs).display_name
  end

  test "line_user_id is unique when present" do
    {:ok, _} = People.create_student(%{display_name: "Kelly", line_user_id: "U123"})

    assert {:error, cs} =
             People.create_student(%{display_name: "Kelly again", line_user_id: "U123"})

    assert "has already been taken" in errors_on(cs).line_user_id
  end

  test "two students may both have no line_user_id" do
    {:ok, _} = People.create_student(%{display_name: "現金學生 A"})
    assert {:ok, _} = People.create_student(%{display_name: "現金學生 B"})
  end

  test "find_by_alias/1 resolves an alias to its student" do
    {:ok, student} = People.create_student(%{display_name: "莉芸"})
    {:ok, _} = People.add_alias(student, "Liyun")

    assert %{id: id} = People.find_by_alias("Liyun")
    assert id == student.id
  end

  test "an alias cannot point at two students" do
    {:ok, a} = People.create_student(%{display_name: "A"})
    {:ok, b} = People.create_student(%{display_name: "B"})
    {:ok, _} = People.add_alias(a, "shared")

    assert {:error, cs} = People.add_alias(b, "shared")
    assert "has already been taken" in errors_on(cs).alias
  end

  test "find_by_alias/1 and find_by_line_user_id/1 return nil when unknown" do
    assert People.find_by_alias("nobody") == nil
    assert People.find_by_line_user_id("Unknown") == nil
    assert People.find_by_line_user_id(nil) == nil
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/people_test.exs`
Expected: FAIL — `Ganesha.People` is undefined.

- [ ] **Step 4: Implement the schemas**

`lib/ganesha/people/student.ex`:

```elixir
defmodule Ganesha.People.Student do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.StudentAlias

  schema "students" do
    field :display_name, :string
    field :line_user_id, :string
    field :active, :boolean, default: true

    has_many :aliases, StudentAlias

    timestamps(type: :utc_datetime)
  end

  def changeset(student, attrs) do
    student
    |> cast(attrs, [:display_name, :line_user_id, :active])
    |> validate_required([:display_name])
    |> unique_constraint(:line_user_id)
  end
end
```

`lib/ganesha/people/student_alias.ex`:

```elixir
defmodule Ganesha.People.StudentAlias do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.Student

  schema "student_aliases" do
    field :alias, :string
    belongs_to :student, Student

    timestamps(type: :utc_datetime)
  end

  def changeset(student_alias, attrs) do
    student_alias
    |> cast(attrs, [:alias, :student_id])
    |> validate_required([:alias, :student_id])
    |> unique_constraint(:alias)
  end
end
```

- [ ] **Step 5: Implement the context**

`lib/ganesha/people.ex`:

```elixir
defmodule Ganesha.People do
  @moduledoc "Students and the names they are known by."

  import Ecto.Query, warn: false
  alias Ganesha.People.{Student, StudentAlias}
  alias Ganesha.Repo

  def list_students do
    Repo.all(from s in Student, order_by: [desc: s.active, asc: s.display_name])
  end

  def list_active_students do
    Repo.all(from s in Student, where: s.active, order_by: s.display_name)
  end

  def get_student!(id), do: Student |> Repo.get!(id) |> Repo.preload(:aliases)

  def create_student(attrs) do
    %Student{} |> Student.changeset(attrs) |> Repo.insert()
  end

  def update_student(%Student{} = student, attrs) do
    student |> Student.changeset(attrs) |> Repo.update()
  end

  def change_student(%Student{} = student, attrs \\ %{}) do
    Student.changeset(student, attrs)
  end

  def add_alias(%Student{} = student, alias_text) do
    %StudentAlias{}
    |> StudentAlias.changeset(%{student_id: student.id, alias: alias_text})
    |> Repo.insert()
  end

  def find_by_alias(alias_text) do
    Repo.one(
      from s in Student,
        join: a in StudentAlias,
        on: a.student_id == s.id,
        where: a.alias == ^alias_text
    )
  end

  def find_by_line_user_id(nil), do: nil

  def find_by_line_user_id(line_user_id) do
    Repo.get_by(Student, line_user_id: line_user_id)
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/people_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add people context with unique student aliases"
```

---

### Task 5: Studio — slots, sessions, style overrides, cancellation

**Files:**
- Create: `lib/ganesha/studio.ex`, `lib/ganesha/studio/slot.ex`, `lib/ganesha/studio/session.ex`
- Create: `priv/repo/migrations/<timestamp>_create_slots_and_sessions.exs`
- Modify: `priv/repo/seeds.exs`
- Test: `test/ganesha/studio_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Clock`.
- Produces: `%Slot{weekday, start_time, end_time, default_style, label, active}` (weekday 1=Monday..7=Sunday, matching `Date.day_of_week/1`); `%Session{slot_id, date, style, state, cancel_reason}` with `state` in `"scheduled" | "cancelled"`; `Studio.list_slots/0`, `Studio.list_active_slots/0`, `Studio.get_slot!/1`, `Studio.create_slot/1`, `Studio.update_slot/2`, `Studio.change_slot/2`, `Studio.generate_month/2`, `Studio.create_session/1`, `Studio.get_session!/1`, `Studio.sessions_for_slot_in_month/2`, `Studio.list_sessions_for_month/1`, `Studio.set_style/2`, `Studio.cancel_session/2`, `Studio.next_session/0`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_slots_and_sessions
```

```elixir
defmodule Ganesha.Repo.Migrations.CreateSlotsAndSessions do
  use Ecto.Migration

  def change do
    create table(:slots) do
      # 1 = Monday .. 7 = Sunday, matching Date.day_of_week/1.
      add :weekday, :integer, null: false
      add :start_time, :time, null: false
      add :end_time, :time, null: false
      add :default_style, :string, null: false
      add :label, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create table(:sessions) do
      add :slot_id, references(:slots, on_delete: :restrict), null: false
      add :date, :date, null: false
      # Overrides the slot's default_style for this date only. This is how
      # "*基礎8/26" on a 流動 slot is represented: style belongs to the date.
      add :style, :string, null: false
      add :state, :string, null: false, default: "scheduled"
      add :cancel_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sessions, [:slot_id, :date])
    create index(:sessions, [:date])
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/studio_test.exs`:

```elixir
defmodule Ganesha.StudioTest do
  use Ganesha.DataCase
  alias Ganesha.Studio

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

  test "generate_month/2 creates one session per matching weekday" do
    slot = monday_slot()
    # August 2026 Mondays: 3, 10, 17, 24, 31.
    assert {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    assert Enum.map(sessions, & &1.date) == [
             ~D[2026-08-03],
             ~D[2026-08-10],
             ~D[2026-08-17],
             ~D[2026-08-24],
             ~D[2026-08-31]
           ]

    assert Enum.all?(sessions, &(&1.style == "基礎"))
    assert Enum.all?(sessions, &(&1.state == "scheduled"))
  end

  test "generate_month/2 is idempotent and preserves a style override" do
    slot = monday_slot()
    {:ok, [first | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, _} = Studio.set_style(first, "流動")

    {:ok, again} = Studio.generate_month(slot, ~D[2026-08-01])

    assert length(again) == 5
    assert Studio.get_session!(first.id).style == "流動"
  end

  test "the same slot and date cannot be created twice" do
    slot = monday_slot()
    {:ok, _} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-08-03], style: "基礎"})

    assert {:error, cs} =
             Studio.create_session(%{slot_id: slot.id, date: ~D[2026-08-03], style: "基礎"})

    assert "has already been taken" in errors_on(cs).slot_id
  end

  test "set_style/2 changes one date only" do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:ok, updated} = Studio.set_style(session, "流動")
    assert updated.style == "流動"

    others = slot |> Studio.sessions_for_slot_in_month(~D[2026-08-01]) |> Enum.drop(1)
    assert Enum.all?(others, &(&1.style == "基礎"))
  end

  test "cancel_session/2 records the state and reason" do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:ok, cancelled} = Studio.cancel_session(session, "颱風假")
    assert cancelled.state == "cancelled"
    assert cancelled.cancel_reason == "颱風假"
  end

  test "cancel_session/2 requires a reason" do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:error, cs} = Studio.cancel_session(session, "")
    assert "can't be blank" in errors_on(cs).cancel_reason
  end

  test "next_session/0 skips cancelled sessions" do
    slot = monday_slot()
    today = Ganesha.Clock.today()

    {:ok, soon} = Studio.create_session(%{slot_id: slot.id, date: today, style: "基礎"})
    {:ok, later} =
      Studio.create_session(%{slot_id: slot.id, date: Date.add(today, 7), style: "基礎"})

    assert Studio.next_session().id == soon.id

    {:ok, _} = Studio.cancel_session(soon, "颱風假")
    assert Studio.next_session().id == later.id
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/studio_test.exs`
Expected: FAIL — `Ganesha.Studio` is undefined.

- [ ] **Step 4: Implement the schemas**

`lib/ganesha/studio/slot.ex`:

```elixir
defmodule Ganesha.Studio.Slot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "slots" do
    field :weekday, :integer
    field :start_time, :time
    field :end_time, :time
    field :default_style, :string
    field :label, :string
    field :active, :boolean, default: true

    has_many :sessions, Ganesha.Studio.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:weekday, :start_time, :end_time, :default_style, :label, :active])
    |> validate_required([:weekday, :start_time, :end_time, :default_style, :label])
    |> validate_inclusion(:weekday, 1..7)
  end
end
```

`lib/ganesha/studio/session.ex`:

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

    belongs_to :slot, Slot

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:slot_id, :date, :style, :state, :cancel_reason])
    |> validate_required([:slot_id, :date, :style, :state])
    |> validate_inclusion(:state, @states)
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
end
```

- [ ] **Step 5: Implement the context**

`lib/ganesha/studio.ex`:

```elixir
defmodule Ganesha.Studio do
  @moduledoc "Recurring weekly slots and the dated sessions they generate."

  import Ecto.Query, warn: false
  alias Ganesha.Clock
  alias Ganesha.Repo
  alias Ganesha.Studio.{Session, Slot}

  def list_slots do
    Repo.all(from s in Slot, order_by: [desc: s.active, asc: s.weekday, asc: s.start_time])
  end

  def list_active_slots do
    Repo.all(from s in Slot, where: s.active, order_by: [asc: s.weekday, asc: s.start_time])
  end

  def get_slot!(id), do: Repo.get!(Slot, id)

  def create_slot(attrs), do: %Slot{} |> Slot.changeset(attrs) |> Repo.insert()

  def update_slot(%Slot{} = slot, attrs), do: slot |> Slot.changeset(attrs) |> Repo.update()

  def change_slot(%Slot{} = slot, attrs \\ %{}), do: Slot.changeset(slot, attrs)

  @doc "Creates a single session. Prefer `generate_month/2` for a whole month."
  def create_session(attrs), do: %Session{} |> Session.changeset(attrs) |> Repo.insert()

  def get_session!(id), do: Session |> Repo.get!(id) |> Repo.preload(:slot)

  @doc """
  Creates a session for every date in `month` matching the slot's weekday.

  Idempotent: dates that already have a session are skipped, so re-running it
  neither duplicates rows nor overwrites a style override or a cancellation.
  Returns all of the month's sessions for the slot, not only the new ones.
  """
  def generate_month(%Slot{} = slot, %Date{} = month) do
    existing = slot |> sessions_for_slot_in_month(month) |> MapSet.new(& &1.date)

    month
    |> dates_in_month_on(slot.weekday)
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.each(fn date ->
      {:ok, _session} = create_session(%{slot_id: slot.id, date: date, style: slot.default_style})
    end)

    {:ok, sessions_for_slot_in_month(slot, month)}
  end

  defp dates_in_month_on(%Date{} = month, weekday) do
    Date.range(Date.beginning_of_month(month), Date.end_of_month(month))
    |> Enum.filter(&(Date.day_of_week(&1) == weekday))
  end

  def sessions_for_slot_in_month(%Slot{} = slot, %Date{} = month) do
    Repo.all(
      from s in Session,
        where:
          s.slot_id == ^slot.id and s.date >= ^Date.beginning_of_month(month) and
            s.date <= ^Date.end_of_month(month),
        order_by: s.date
    )
  end

  def list_sessions_for_month(%Date{} = month) do
    Repo.all(
      from s in Session,
        where: s.date >= ^Date.beginning_of_month(month) and s.date <= ^Date.end_of_month(month),
        order_by: [asc: s.date],
        preload: [:slot]
    )
  end

  def set_style(%Session{} = session, style) do
    session |> Session.changeset(%{style: style}) |> Repo.update()
  end

  @doc """
  Marks a session cancelled.

  Credit issuance is deliberately NOT done here: `Ganesha.Roster` owns credits,
  and the caller issues them so the two steps are visible at the call site.
  """
  def cancel_session(%Session{} = session, reason) do
    session |> Session.cancellation_changeset(reason) |> Repo.update()
  end

  @doc "The next scheduled session today or later, in Taipei terms."
  def next_session do
    today = Clock.today()

    Repo.one(
      from s in Session,
        where: s.date >= ^today and s.state == "scheduled",
        order_by: [asc: s.date],
        limit: 1,
        preload: [:slot]
    )
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/studio_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 7: Seed the four real slots**

Append to `priv/repo/seeds.exs`:

```elixir
for attrs <- [
      %{weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"},
      %{weekday: 1, start_time: ~T[15:30:00], end_time: ~T[16:45:00],
        default_style: "基礎", label: "午後練習｜週一 基礎瑜伽"},
      %{weekday: 3, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "流動", label: "早晨練習｜週三 和緩流動"},
      %{weekday: 5, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週五 基礎瑜伽"}
    ] do
  case Ganesha.Repo.get_by(Ganesha.Studio.Slot,
         weekday: attrs.weekday,
         start_time: attrs.start_time
       ) do
    nil -> {:ok, _} = Ganesha.Studio.create_slot(attrs)
    _existing -> :ok
  end
end
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add studio context with idempotent month generation"
```

---

### Task 6: Sales — purchases with a freeform amount override

**Files:**
- Create: `lib/ganesha/sales.ex`, `lib/ganesha/sales/purchase.ex`
- Create: `priv/repo/migrations/<timestamp>_create_purchases.exs`
- Test: `test/ganesha/sales/purchase_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Catalog.Package`, `Ganesha.People.Student`, `Ganesha.Studio.Slot`, `Catalog.price_for/2`.
- Produces: `%Ganesha.Sales.Purchase{student_id, package_id, slot_id, list_price, custom_amount, note}`; `Sales.create_purchase/1`, `Sales.update_purchase/2`, `Sales.change_purchase/2`, `Sales.get_purchase!/1`, `Sales.payable/1`, `Sales.comped/1`, `Sales.list_purchases_for_student/1`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_purchases
```

```elixir
defmodule Ganesha.Repo.Migrations.CreatePurchases do
  use Ecto.Migration

  def change do
    create table(:purchases) do
      add :student_id, references(:students, on_delete: :restrict), null: false
      add :package_id, references(:packages, on_delete: :restrict), null: false
      # Set for monthly purchases only. A drop-in is not tied to a slot.
      add :slot_id, references(:slots, on_delete: :restrict)
      # Snapshot of the package price at sale time, so the price list can change
      # without rewriting history, and so an override is visible not silent.
      add :list_price, :integer, null: false
      # Freeform override. NULL means "charge list_price". Zero is meaningful:
      # 按摩器代購 is custom_amount 0 plus a note, not a null amount.
      add :custom_amount, :integer
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:purchases, [:student_id])
    create index(:purchases, [:package_id])
    create index(:purchases, [:slot_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/sales/purchase_test.exs`:

```elixir
defmodule Ganesha.Sales.PurchaseTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Sales}

  defp student_and_monthly do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {student, monthly}
  end

  test "payable/1 is list_price when there is no override" do
    {student, monthly} = student_and_monthly()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1600
      })

    assert Sales.payable(purchase) == 1600
    assert Sales.comped(purchase) == 0
  end

  test "payable/1 uses the override, and zero is a real value" do
    {student, monthly} = student_and_monthly()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1600,
        custom_amount: 0,
        note: "按摩器代購"
      })

    assert Sales.payable(purchase) == 0
    assert Sales.comped(purchase) == 1600
    assert purchase.note == "按摩器代購"
  end

  test "the override may exceed the list price" do
    {student, monthly} = student_and_monthly()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1200,
        custom_amount: 1500
      })

    assert Sales.payable(purchase) == 1500
    assert Sales.comped(purchase) == -300
  end

  test "rejects a negative list price or override" do
    {student, monthly} = student_and_monthly()
    base = %{student_id: student.id, package_id: monthly.id}

    assert {:error, cs} = Sales.create_purchase(Map.put(base, :list_price, -1))
    assert "must be greater than or equal to 0" in errors_on(cs).list_price

    attrs = base |> Map.put(:list_price, 100) |> Map.put(:custom_amount, -5)
    assert {:error, cs} = Sales.create_purchase(attrs)
    assert "must be greater than or equal to 0" in errors_on(cs).custom_amount
  end

  test "both of the August two-class prices are representable and distinguishable" do
    {student, monthly} = student_and_monthly()

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    # 素容: two classes bought at the drop-in rate = 900.
    {:ok, su} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: drop_in.id,
        list_price: Catalog.price_for(drop_in, 2)
      })

    # 彩華: two classes bought at the monthly package rate = 800.
    {:ok, cai} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: Catalog.price_for(monthly, 2)
      })

    assert Sales.payable(su) == 900
    assert Sales.payable(cai) == 800
    refute su.package_id == cai.package_id
  end

  test "list_purchases_for_student/1 preloads the package" do
    {student, monthly} = student_and_monthly()

    {:ok, _} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1600
      })

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.package.name == "月課程"
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/sales/purchase_test.exs`
Expected: FAIL — `Ganesha.Sales` is undefined.

- [ ] **Step 4: Implement the schema**

`lib/ganesha/sales/purchase.ex`:

```elixir
defmodule Ganesha.Sales.Purchase do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Catalog.Package
  alias Ganesha.People.Student
  alias Ganesha.Studio.Slot

  schema "purchases" do
    field :list_price, :integer
    field :custom_amount, :integer
    field :note, :string

    belongs_to :student, Student
    belongs_to :package, Package
    belongs_to :slot, Slot

    timestamps(type: :utc_datetime)
  end

  def changeset(purchase, attrs) do
    purchase
    |> cast(attrs, [:student_id, :package_id, :slot_id, :list_price, :custom_amount, :note])
    |> validate_required([:student_id, :package_id, :list_price])
    |> validate_number(:list_price, greater_than_or_equal_to: 0)
    |> validate_number(:custom_amount, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:student_id)
    |> foreign_key_constraint(:package_id)
    |> foreign_key_constraint(:slot_id)
  end
end
```

- [ ] **Step 5: Implement the context**

`lib/ganesha/sales.ex`:

```elixir
defmodule Ganesha.Sales do
  @moduledoc """
  Purchases (the money side of a sale) and the payments settling them.

  A purchase has no month of its own. Its period is derived from the dates of
  the attendance rows that reference it, which is why there is no month column
  anywhere in this schema.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Repo
  alias Ganesha.Sales.Purchase

  def get_purchase!(id) do
    Purchase |> Repo.get!(id) |> Repo.preload([:student, :package, :slot])
  end

  def create_purchase(attrs) do
    %Purchase{} |> Purchase.changeset(attrs) |> Repo.insert()
  end

  def update_purchase(%Purchase{} = purchase, attrs) do
    purchase |> Purchase.changeset(attrs) |> Repo.update()
  end

  def change_purchase(%Purchase{} = purchase, attrs \\ %{}) do
    Purchase.changeset(purchase, attrs)
  end

  @doc """
  What the student owes for this purchase: the override when set, else list price.

  She records final agreed numbers rather than discounts, so the override is a
  plain replacement and no arithmetic has to stay consistent.
  """
  @spec payable(Purchase.t()) :: integer()
  def payable(%Purchase{custom_amount: nil, list_price: list_price}), do: list_price
  def payable(%Purchase{custom_amount: custom_amount}), do: custom_amount

  @doc "How much was given away against list price. Negative means she charged more."
  @spec comped(Purchase.t()) :: integer()
  def comped(%Purchase{} = purchase), do: purchase.list_price - payable(purchase)

  def list_purchases_for_student(student_id) do
    Repo.all(
      from p in Purchase,
        where: p.student_id == ^student_id,
        order_by: [desc: p.inserted_at],
        preload: [:package, :slot]
    )
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/sales/purchase_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add purchases with freeform amount override"
```

---

### Task 7: Sales — payments and the human-only confirmation boundary

**Files:**
- Create: `lib/ganesha/sales/payment.ex`
- Modify: `lib/ganesha/sales.ex` (append payment functions inside the module)
- Create: `priv/repo/migrations/<timestamp>_create_payments.exs`
- Test: `test/ganesha/sales/payment_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Sales.Purchase`, `Ganesha.Clock`.
- Produces: `%Ganesha.Sales.Payment{purchase_id, amount, method, state, paid_on, reported_last5, source, note, confirmed_at, confirmed_by}` with `method` in `"line_pay" | "line_bank" | "cash" | "other"`, `state` in `"claimed" | "confirmed" | "disputed"`, `source` in `"manual" | "line_draft"`; `Sales.record_payment/1`, `Sales.change_payment/2`, `Sales.confirm_payment/2`, `Sales.dispute_payment/2`, `Sales.list_payments_for_purchase/1`, `Sales.suspicious_last5?/1`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_payments
```

```elixir
defmodule Ganesha.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments) do
      add :purchase_id, references(:purchases, on_delete: :restrict), null: false
      # The amount applied to THIS purchase, not the bank transaction total.
      # One transfer split across two slots is recorded as two rows.
      add :amount, :integer, null: false
      add :method, :string, null: false
      add :state, :string, null: false, default: "claimed"
      add :paid_on, :date, null: false
      # 帳後五碼. Deliberately NOT unique: split rows share it legitimately.
      add :reported_last5, :string
      add :source, :string, null: false, default: "manual"
      add :note, :string
      add :confirmed_at, :utc_datetime
      add :confirmed_by, :string

      timestamps(type: :utc_datetime)
    end

    create index(:payments, [:purchase_id])
    create index(:payments, [:state])
    create index(:payments, [:reported_last5])
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/sales/payment_test.exs`:

```elixir
defmodule Ganesha.Sales.PaymentTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, Clock, People, Sales}

  defp purchase_fixture(student_name \\ nil) do
    name = student_name || "S#{System.unique_integer([:positive])}"
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "pkg-#{System.unique_integer([:positive])}",
        kind: "monthly",
        price_per_class: 400
      })

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    purchase
  end

  test "a recorded payment starts as a claim" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_pay",
        paid_on: Clock.today()
      })

    assert payment.state == "claimed"
    assert is_nil(payment.confirmed_at)
    assert is_nil(payment.confirmed_by)
  end

  test "record_payment/1 cannot be tricked into creating a confirmed payment" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: Clock.today(),
        state: "confirmed",
        confirmed_at: DateTime.utc_now(),
        confirmed_by: "sneaky"
      })

    assert payment.state == "claimed", "state must not be castable"
    assert is_nil(payment.confirmed_at)
    assert is_nil(payment.confirmed_by)
  end

  test "confirm_payment/2 stamps who confirmed it and when" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_bank",
        paid_on: Clock.today(),
        reported_last5: "12345"
      })

    assert {:ok, confirmed} = Sales.confirm_payment(payment, "teacher@example.com")
    assert confirmed.state == "confirmed"
    assert confirmed.confirmed_by == "teacher@example.com"
    refute is_nil(confirmed.confirmed_at)
  end

  test "confirm_payment/2 refuses an empty confirmer" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 100,
        method: "cash",
        paid_on: Clock.today()
      })

    assert {:error, cs} = Sales.confirm_payment(payment, "")
    assert "can't be blank" in errors_on(cs).confirmed_by
  end

  test "dispute_payment/2 records the reason" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 100,
        method: "cash",
        paid_on: Clock.today()
      })

    assert {:ok, disputed} = Sales.dispute_payment(payment, "銀行沒有這筆")
    assert disputed.state == "disputed"
    assert disputed.note == "銀行沒有這筆"
  end

  test "rejects an unknown method, a negative amount, and a bad last5" do
    purchase = purchase_fixture()
    base = %{purchase_id: purchase.id, paid_on: Clock.today()}

    assert {:error, cs} = Sales.record_payment(Map.merge(base, %{amount: 100, method: "bitcoin"}))
    assert "is invalid" in errors_on(cs).method

    assert {:error, cs} = Sales.record_payment(Map.merge(base, %{amount: -1, method: "cash"}))
    assert "must be greater than or equal to 0" in errors_on(cs).amount

    attrs = Map.merge(base, %{amount: 100, method: "cash", reported_last5: "abcde"})
    assert {:error, cs} = Sales.record_payment(attrs)
    assert "must be up to five digits" in errors_on(cs).reported_last5
  end

  describe "suspicious_last5?/1 — split-aware duplicate detection" do
    test "same student, same day, different purchases is a split and not suspicious" do
      {:ok, student} = People.create_student(%{display_name: "彩華"})

      {:ok, pkg} =
        Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

      {:ok, mon} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 800})

      {:ok, wed} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1200})

      today = Clock.today()

      {:ok, _first} =
        Sales.record_payment(%{
          purchase_id: mon.id, amount: 800, method: "line_pay",
          paid_on: today, reported_last5: "54321"
        })

      {:ok, second} =
        Sales.record_payment(%{
          purchase_id: wed.id, amount: 1200, method: "line_pay",
          paid_on: today, reported_last5: "54321"
        })

      refute Sales.suspicious_last5?(second)
    end

    test "two rows against the same purchase sharing a last5 is suspicious" do
      purchase = purchase_fixture()
      today = Clock.today()

      {:ok, _} =
        Sales.record_payment(%{
          purchase_id: purchase.id, amount: 1600, method: "line_pay",
          paid_on: today, reported_last5: "99999"
        })

      {:ok, dup} =
        Sales.record_payment(%{
          purchase_id: purchase.id, amount: 1600, method: "line_pay",
          paid_on: today, reported_last5: "99999"
        })

      assert Sales.suspicious_last5?(dup)
    end

    test "the same last5 from a different student is suspicious" do
      a = purchase_fixture("A")
      b = purchase_fixture("B")
      today = Clock.today()

      {:ok, _} =
        Sales.record_payment(%{
          purchase_id: a.id, amount: 400, method: "line_pay",
          paid_on: today, reported_last5: "11111"
        })

      {:ok, other} =
        Sales.record_payment(%{
          purchase_id: b.id, amount: 400, method: "line_pay",
          paid_on: today, reported_last5: "11111"
        })

      assert Sales.suspicious_last5?(other)
    end

    test "a payment with no reported last5 is never suspicious" do
      purchase = purchase_fixture()

      {:ok, payment} =
        Sales.record_payment(%{
          purchase_id: purchase.id, amount: 400, method: "cash", paid_on: Clock.today()
        })

      refute Sales.suspicious_last5?(payment)
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/sales/payment_test.exs`
Expected: FAIL — `Ganesha.Sales.record_payment/1` is undefined.

- [ ] **Step 4: Implement the payment schema with separate changesets**

`lib/ganesha/sales/payment.ex`:

```elixir
defmodule Ganesha.Sales.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Sales.Purchase

  @methods ~w(line_pay line_bank cash other)
  @sources ~w(manual line_draft)
  @states ~w(claimed confirmed disputed)

  schema "payments" do
    field :amount, :integer
    field :method, :string
    field :state, :string, default: "claimed"
    field :paid_on, :date
    field :reported_last5, :string
    field :source, :string, default: "manual"
    field :note, :string
    field :confirmed_at, :utc_datetime
    field :confirmed_by, :string

    belongs_to :purchase, Purchase

    timestamps(type: :utc_datetime)
  end

  def methods, do: @methods
  def sources, do: @sources
  def states, do: @states

  @doc """
  Recording a payment.

  `state`, `confirmed_at` and `confirmed_by` are deliberately absent from
  `cast/3`: a payment may only become confirmed through
  `confirmation_changeset/2`, which demands a human identity. The trust
  boundary is enforced by the shape of this function, not by a comment.
  """
  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:purchase_id, :amount, :method, :paid_on, :reported_last5, :source, :note])
    |> validate_required([:purchase_id, :amount, :method, :paid_on])
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> validate_inclusion(:method, @methods)
    |> validate_inclusion(:source, @sources)
    |> validate_format(:reported_last5, ~r/^\d{1,5}$/, message: "must be up to five digits")
    |> put_change(:state, "claimed")
    |> foreign_key_constraint(:purchase_id)
  end

  @doc "The only path to a confirmed payment. Requires who confirmed it."
  def confirmation_changeset(payment, confirmed_by) do
    payment
    |> cast(%{confirmed_by: confirmed_by}, [:confirmed_by])
    |> validate_required([:confirmed_by])
    |> put_change(:state, "confirmed")
    |> put_change(:confirmed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def dispute_changeset(payment, reason) do
    payment
    |> cast(%{note: reason}, [:note])
    |> put_change(:state, "disputed")
  end
end
```

`validate_format/4` skips `nil`, so a payment without `reported_last5` passes.

- [ ] **Step 5: Append payment functions to the Sales context**

Add inside `defmodule Ganesha.Sales`, after the purchase functions:

```elixir
  alias Ganesha.Sales.Payment

  def record_payment(attrs) do
    %Payment{} |> Payment.changeset(attrs) |> Repo.insert()
  end

  def change_payment(%Payment{} = payment, attrs \\ %{}) do
    Payment.changeset(payment, attrs)
  end

  @doc """
  Confirms that the money actually arrived.

  Only ever called from a human action in the UI. No API in Taiwan can tell
  this application that a personal transfer landed, so this is an assertion by
  the teacher, and the schema records who made it.
  """
  def confirm_payment(%Payment{} = payment, confirmed_by) do
    payment |> Payment.confirmation_changeset(confirmed_by) |> Repo.update()
  end

  def dispute_payment(%Payment{} = payment, reason) do
    payment |> Payment.dispute_changeset(reason) |> Repo.update()
  end

  def list_payments_for_purchase(purchase_id) do
    Repo.all(from p in Payment, where: p.purchase_id == ^purchase_id, order_by: p.paid_on)
  end

  @doc """
  Whether a repeated 帳後五碼 looks like a mistake rather than a deliberate split.

  One bank transfer may be recorded as several payment rows, so a shared
  `reported_last5` is normal. It is only suspicious when the rows belong to
  different students, or when more than one row sits against the same purchase.
  """
  @spec suspicious_last5?(Payment.t()) :: boolean()
  def suspicious_last5?(%Payment{reported_last5: nil}), do: false

  def suspicious_last5?(%Payment{} = payment) do
    student_id =
      Repo.one!(from p in Purchase, where: p.id == ^payment.purchase_id, select: p.student_id)

    Repo.all(
      from pay in Payment,
        join: pur in Purchase,
        on: pur.id == pay.purchase_id,
        where: pay.reported_last5 == ^payment.reported_last5 and pay.id != ^payment.id,
        select: %{purchase_id: pay.purchase_id, student_id: pur.student_id}
    )
    |> Enum.any?(fn sibling ->
      sibling.student_id != student_id or sibling.purchase_id == payment.purchase_id
    end)
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/sales/payment_test.exs`
Expected: PASS, 11 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add payments with human-only confirmation and split-aware duplicate check"
```

---

### Task 8: Roster — attendance rows and the no-show mark

**Files:**
- Create: `lib/ganesha/roster.ex`, `lib/ganesha/roster/attendance.ex`
- Create: `priv/repo/migrations/<timestamp>_create_attendances.exs`
- Test: `test/ganesha/roster/attendance_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Studio.Session`, `Ganesha.People.Student`, `Ganesha.Sales.Purchase`.
- Produces: `%Ganesha.Roster.Attendance{session_id, student_id, kind, purchase_id, credit_id, state, note}` with `kind` in `"enrolled" | "makeup" | "drop_in" | "trial"` and `state` in `"expected" | "no_show"`; `Roster.create_attendance/1`, `Roster.enroll/3`, `Roster.add_drop_in/3`, `Roster.mark_no_show/1`, `Roster.mark_expected/1`, `Roster.get_attendance!/1`, `Roster.list_for_session/1`, `Roster.list_for_student/1`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_attendances
```

```elixir
defmodule Ganesha.Repo.Migrations.CreateAttendances do
  use Ecto.Migration

  def change do
    create table(:attendances) do
      add :session_id, references(:sessions, on_delete: :restrict), null: false
      add :student_id, references(:students, on_delete: :restrict), null: false
      add :kind, :string, null: false
      # NULL for a makeup: there is no sale behind it, a credit pays for it.
      # 允一's "無費用，補颱風假" row is exactly this shape.
      add :purchase_id, references(:purchases, on_delete: :restrict)
      # Plain integer, not a reference: the credits table is created in Task 9,
      # and SQLite cannot add a foreign key to an existing table afterwards.
      add :credit_id, :integer
      add :state, :string, null: false, default: "expected"
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:attendances, [:session_id, :student_id])
    create index(:attendances, [:purchase_id])
    create index(:attendances, [:student_id])
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/roster/attendance_test.exs`:

```elixir
defmodule Ganesha.Roster.AttendanceTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  defp august_setup do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1
      })

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id, package_id: pkg.id, slot_id: slot.id, list_price: 1600
      })

    %{slot: slot, sessions: sessions, student: student, purchase: purchase}
  end

  test "enroll/3 seats a student against a purchase" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()

    assert {:ok, att} = Roster.enroll(session, student, purchase)
    assert att.kind == "enrolled"
    assert att.state == "expected"
    assert att.purchase_id == purchase.id
  end

  test "a student cannot be seated twice on one session" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()
    {:ok, _} = Roster.enroll(session, student, purchase)

    assert {:error, cs} = Roster.enroll(session, student, purchase)
    assert "has already been taken" in errors_on(cs).session_id
  end

  test "add_drop_in/3 records kind from the package: drop_in" do
    %{sessions: [session | _]} = august_setup()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: jennifer.id, package_id: pkg.id, list_price: 450})

    assert {:ok, att} = Roster.add_drop_in(session, jennifer, purchase)
    assert att.kind == "drop_in"
  end

  test "add_drop_in/3 records kind from the package: trial" do
    %{sessions: [session | _]} = august_setup()
    {:ok, yufang} = People.create_student(%{display_name: "育芳"})

    {:ok, pkg} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 450})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: yufang.id, package_id: pkg.id, list_price: 450})

    assert {:ok, att} = Roster.add_drop_in(session, yufang, purchase)
    assert att.kind == "trial"
  end

  test "mark_no_show/1 and mark_expected/1 flip the state" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()
    {:ok, att} = Roster.enroll(session, student, purchase)

    assert {:ok, absent} = Roster.mark_no_show(att)
    assert absent.state == "no_show"

    assert {:ok, back} = Roster.mark_expected(absent)
    assert back.state == "expected"
  end

  test "list_for_session/1 preloads the student" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()
    {:ok, _} = Roster.enroll(session, student, purchase)

    assert [row] = Roster.list_for_session(session)
    assert row.student.display_name == "Lulu"
  end

  test "rejects an unknown kind" do
    %{sessions: [session | _], student: student} = august_setup()

    assert {:error, cs} =
             Roster.create_attendance(%{
               session_id: session.id, student_id: student.id, kind: "guest"
             })

    assert "is invalid" in errors_on(cs).kind
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/roster/attendance_test.exs`
Expected: FAIL — `Ganesha.Roster` is undefined.

- [ ] **Step 4: Implement the schema**

`lib/ganesha/roster/attendance.ex`:

```elixir
defmodule Ganesha.Roster.Attendance do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.Student
  alias Ganesha.Sales.Purchase
  alias Ganesha.Studio.Session

  @kinds ~w(enrolled makeup drop_in trial)
  @states ~w(expected no_show)

  schema "attendances" do
    field :kind, :string
    field :state, :string, default: "expected"
    field :note, :string
    field :credit_id, :integer

    belongs_to :session, Session
    belongs_to :student, Student
    belongs_to :purchase, Purchase

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def states, do: @states

  def changeset(attendance, attrs) do
    attendance
    |> cast(attrs, [:session_id, :student_id, :kind, :purchase_id, :credit_id, :state, :note])
    |> validate_required([:session_id, :student_id, :kind, :state])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:session_id, :student_id],
      name: "attendances_session_id_student_id_index"
    )
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:student_id)
    |> foreign_key_constraint(:purchase_id)
  end
end
```

- [ ] **Step 5: Implement the context**

`lib/ganesha/roster.ex`:

```elixir
defmodule Ganesha.Roster do
  @moduledoc """
  Attendance rows and makeup credits.

  An attendance row is the only thing that puts a name on a date. Every kind of
  participation flows through it: a monthly enrollment, a drop-in, a trial, or a
  makeup paid for by a credit rather than by a sale.
  """

  import Ecto.Query, warn: false
  alias Ganesha.People.Student
  alias Ganesha.Repo
  alias Ganesha.Roster.Attendance
  alias Ganesha.Sales.Purchase
  alias Ganesha.Studio.Session

  def create_attendance(attrs) do
    %Attendance{} |> Attendance.changeset(attrs) |> Repo.insert()
  end

  def enroll(%Session{} = session, %Student{} = student, %Purchase{} = purchase) do
    create_attendance(%{
      session_id: session.id,
      student_id: student.id,
      purchase_id: purchase.id,
      kind: "enrolled"
    })
  end

  @doc "Seats a non-enrolled attendee. The kind follows the purchase's package."
  def add_drop_in(%Session{} = session, %Student{} = student, %Purchase{} = purchase) do
    kind = if purchase_package_kind(purchase) == "trial", do: "trial", else: "drop_in"

    create_attendance(%{
      session_id: session.id,
      student_id: student.id,
      purchase_id: purchase.id,
      kind: kind
    })
  end

  defp purchase_package_kind(%Purchase{} = purchase) do
    purchase = Repo.preload(purchase, :package)
    purchase.package.kind
  end

  def mark_no_show(%Attendance{} = attendance) do
    attendance |> Attendance.changeset(%{state: "no_show"}) |> Repo.update()
  end

  def mark_expected(%Attendance{} = attendance) do
    attendance |> Attendance.changeset(%{state: "expected"}) |> Repo.update()
  end

  def get_attendance!(id) do
    Attendance |> Repo.get!(id) |> Repo.preload([:student, session: :slot])
  end

  def list_for_session(%Session{} = session) do
    Repo.all(
      from a in Attendance,
        where: a.session_id == ^session.id,
        order_by: a.id,
        preload: [:student, purchase: :package]
    )
  end

  def list_for_student(student_id) do
    Repo.all(
      from a in Attendance,
        where: a.student_id == ^student_id,
        order_by: [desc: a.id],
        preload: [session: :slot]
    )
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/roster/attendance_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add attendance rows with unique seating and no-show mark"
```

---

### Task 9: Roster — makeup credits, expiry, and the consumption guard

**Files:**
- Create: `lib/ganesha/roster/credit.ex`
- Modify: `lib/ganesha/roster.ex` (append credit functions inside the module)
- Create: `priv/repo/migrations/<timestamp>_create_credits.exs`
- Test: `test/ganesha/roster/credit_test.exs`

**Interfaces:**
- Consumes: `Roster.Attendance`, `Studio.Session`, `Sales.Purchase`, `Catalog.Package`, `Ganesha.Clock`.
- Produces: `%Ganesha.Roster.Credit{student_id, source, seq, origin_purchase_id, origin_session_id, expires_on, consumed_by_attendance_id, note}` with `source` in `"package" | "cancellation"`; `Roster.mint_package_credits/1`, `Roster.issue_cancellation_credits/1`, `Roster.available_credits/2`, `Roster.book_makeup/3`, `Roster.expired_credits/0`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_credits
```

```elixir
defmodule Ganesha.Repo.Migrations.CreateCredits do
  use Ecto.Migration

  def change do
    create table(:credits) do
      add :student_id, references(:students, on_delete: :restrict), null: false
      add :source, :string, null: false
      # Ordinal within one purchase's grant, so re-running minting collides on
      # the partial unique index below rather than duplicating credits.
      add :seq, :integer
      add :origin_purchase_id, references(:purchases, on_delete: :restrict)
      add :origin_session_id, references(:sessions, on_delete: :restrict)
      # NULL means it never expires, which is the case for a cancellation credit.
      # July's 颱風假 credits were still being spent in August.
      add :expires_on, :date
      add :consumed_by_attendance_id, references(:attendances, on_delete: :restrict)
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:credits, [:student_id])
    create index(:credits, [:consumed_by_attendance_id])

    # SQLite supports partial indexes, and cannot ALTER TABLE ADD CONSTRAINT,
    # so these are where idempotency is actually guaranteed rather than merely
    # attempted in application code.
    create unique_index(:credits, [:origin_purchase_id, :seq],
             where: "source = 'package'",
             name: "credits_package_grant_index"
           )

    create unique_index(:credits, [:origin_session_id, :student_id],
             where: "source = 'cancellation'",
             name: "credits_cancellation_grant_index"
           )
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/roster/credit_test.exs`:

```elixir
defmodule Ganesha.Roster.CreditTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Repo, Roster, Sales, Studio}

  defp monday_slot_with_sessions do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {slot, sessions}
  end

  defp friday_slot_with_sessions do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 5, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週五 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {slot, sessions}
  end

  defp enrolled_monthly(slot, sessions, name) do
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "月課程-#{System.unique_integer([:positive])}",
        kind: "monthly", price_per_class: 400, included_makeups: 1
      })

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id, package_id: pkg.id, slot_id: slot.id, list_price: 1600
      })

    for session <- sessions, do: {:ok, _} = Roster.enroll(session, student, purchase)
    %{student: student, purchase: purchase}
  end

  test "mint_package_credits/1 expires the credit at the Taipei month end" do
    {slot, sessions} = monday_slot_with_sessions()
    %{purchase: purchase, student: student} = enrolled_monthly(slot, sessions, "Lulu")

    assert {:ok, [credit]} = Roster.mint_package_credits(purchase)
    assert credit.source == "package"
    assert credit.student_id == student.id
    # Earliest attended session is 2026-08-03, so expiry is the end of August.
    assert credit.expires_on == ~D[2026-08-31]
  end

  test "mint_package_credits/1 is idempotent" do
    {slot, sessions} = monday_slot_with_sessions()
    %{purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")

    {:ok, first} = Roster.mint_package_credits(purchase)
    {:ok, second} = Roster.mint_package_credits(purchase)

    assert length(first) == 1
    assert length(second) == 1
    assert hd(first).id == hd(second).id
  end

  test "mint_package_credits/1 grants nothing until the purchase has attendance" do
    {slot, _sessions} = monday_slot_with_sessions()
    {:ok, student} = People.create_student(%{display_name: "Nobody"})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1
      })

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id, package_id: pkg.id, slot_id: slot.id, list_price: 1600
      })

    assert {:ok, []} = Roster.mint_package_credits(purchase),
           "a purchase has no month until it has attendance rows"
  end

  test "a drop-in package grants no credit" do
    {_slot, sessions} = monday_slot_with_sessions()
    {:ok, student} = People.create_student(%{display_name: "Jennifer"})

    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 450})

    {:ok, _} = Roster.add_drop_in(hd(sessions), student, purchase)

    assert {:ok, []} = Roster.mint_package_credits(purchase)
  end

  test "issue_cancellation_credits/1 grants one never-expiring credit per enrolled student" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: lanzi} = enrolled_monthly(slot, sessions, "蘭子")
    %{student: dandan} = enrolled_monthly(slot, sessions, "丹丹")

    {:ok, cancelled} = Studio.cancel_session(hd(sessions), "颱風假")

    assert {:ok, credits} = Roster.issue_cancellation_credits(cancelled)
    assert length(credits) == 2
    assert Enum.all?(credits, &(&1.source == "cancellation"))
    assert Enum.all?(credits, &is_nil(&1.expires_on))
    assert Enum.all?(credits, &(&1.note == "颱風假"))
    assert Enum.sort(Enum.map(credits, & &1.student_id)) == Enum.sort([lanzi.id, dandan.id])
  end

  test "issue_cancellation_credits/1 is idempotent" do
    {slot, sessions} = monday_slot_with_sessions()
    _ = enrolled_monthly(slot, sessions, "蘭子")
    {:ok, cancelled} = Studio.cancel_session(hd(sessions), "颱風假")

    {:ok, first} = Roster.issue_cancellation_credits(cancelled)
    {:ok, second} = Roster.issue_cancellation_credits(cancelled)

    assert length(first) == 1
    assert hd(first).id == hd(second).id
  end

  test "book_makeup/3 spends a credit on another weekday and creates a free row" do
    {monday, monday_sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(monday, monday_sessions, "蘭子")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)

    {_friday, friday_sessions} = friday_slot_with_sessions()
    target = hd(friday_sessions)

    assert {:ok, attendance} = Roster.book_makeup(target, student, credit)
    assert attendance.kind == "makeup"
    assert is_nil(attendance.purchase_id), "a makeup has no sale behind it"
    assert attendance.credit_id == credit.id

    assert Roster.available_credits(student.id, target.date) == [],
           "the credit must be spent, not merely referenced"
  end

  test "book_makeup/3 refuses a credit belonging to another student" do
    {slot, sessions} = monday_slot_with_sessions()
    %{purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)
    {:ok, stranger} = People.create_student(%{display_name: "Stranger"})

    assert {:error, :credit_not_owned} =
             Roster.book_makeup(Enum.at(sessions, 1), stranger, credit)
  end

  test "book_makeup/3 refuses an already spent credit" do
    {monday, monday_sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(monday, monday_sessions, "Lulu")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)

    {_friday, friday_sessions} = friday_slot_with_sessions()
    {:ok, _} = Roster.book_makeup(Enum.at(friday_sessions, 0), student, credit)

    reloaded = Repo.reload!(credit)

    assert {:error, :credit_already_consumed} =
             Roster.book_makeup(Enum.at(friday_sessions, 1), student, reloaded)
  end

  test "book_makeup/3 refuses a credit that expired before the session date" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)

    {:ok, tuesday} =
      Studio.create_slot(%{
        weekday: 2, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "週二"
      })

    {:ok, september} = Studio.generate_month(tuesday, ~D[2026-09-01])

    assert {:error, :credit_expired} = Roster.book_makeup(hd(september), student, credit)
  end

  test "a cancellation credit still works in a later month" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: student} = enrolled_monthly(slot, sessions, "蘭子")
    {:ok, cancelled} = Studio.cancel_session(hd(sessions), "颱風假")
    {:ok, [credit]} = Roster.issue_cancellation_credits(cancelled)

    {:ok, tuesday} =
      Studio.create_slot(%{
        weekday: 2, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "週二"
      })

    {:ok, september} = Studio.generate_month(tuesday, ~D[2026-09-01])

    assert {:ok, attendance} = Roster.book_makeup(hd(september), student, credit)
    assert attendance.kind == "makeup"
  end

  test "available_credits/2 excludes expired and spent credits" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")
    {:ok, _} = Roster.mint_package_credits(purchase)

    assert length(Roster.available_credits(student.id, ~D[2026-08-20])) == 1
    assert Roster.available_credits(student.id, ~D[2026-09-01]) == []
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/roster/credit_test.exs`
Expected: FAIL — `Ganesha.Roster.Credit` is undefined.

- [ ] **Step 4: Implement the credit schema**

`lib/ganesha/roster/credit.ex`:

```elixir
defmodule Ganesha.Roster.Credit do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.Student
  alias Ganesha.Roster.Attendance
  alias Ganesha.Sales.Purchase
  alias Ganesha.Studio.Session

  @sources ~w(package cancellation)

  schema "credits" do
    field :source, :string
    field :seq, :integer
    field :expires_on, :date
    field :note, :string

    belongs_to :student, Student
    belongs_to :origin_purchase, Purchase
    belongs_to :origin_session, Session
    belongs_to :consumed_by_attendance, Attendance

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources

  def changeset(credit, attrs) do
    credit
    |> cast(attrs, [
      :student_id,
      :source,
      :seq,
      :origin_purchase_id,
      :origin_session_id,
      :expires_on,
      :consumed_by_attendance_id,
      :note
    ])
    |> validate_required([:student_id, :source])
    |> validate_inclusion(:source, @sources)
    |> unique_constraint([:origin_purchase_id, :seq], name: "credits_package_grant_index")
    |> unique_constraint([:origin_session_id, :student_id],
      name: "credits_cancellation_grant_index"
    )
  end

  @doc "Marks the credit spent by a specific makeup attendance."
  def consumption_changeset(credit, %Attendance{} = attendance) do
    change(credit, %{consumed_by_attendance_id: attendance.id})
  end
end
```

- [ ] **Step 5: Append credit functions to the Roster context**

Add inside `defmodule Ganesha.Roster`, after the attendance functions:

```elixir
  alias Ganesha.Clock
  alias Ganesha.Roster.Credit

  @doc """
  Grants a monthly purchase's included makeups.

  Called once the purchase has attendance rows rather than at creation time: a
  purchase has no month of its own, so expiry is the last day of the calendar
  month of its earliest attended session, evaluated in Taipei. Idempotent via
  the partial unique index on `(origin_purchase_id, seq)`.
  """
  def mint_package_credits(%Purchase{} = purchase) do
    purchase = Repo.preload(purchase, :package)

    case {purchase.package.included_makeups, earliest_session_date(purchase)} do
      {0, _} ->
        {:ok, []}

      {_count, nil} ->
        {:ok, []}

      {count, %Date{} = earliest} ->
        expires_on = Clock.end_of_month(earliest)

        credits =
          Enum.map(1..count, fn seq ->
            attrs = %{
              student_id: purchase.student_id,
              source: "package",
              seq: seq,
              origin_purchase_id: purchase.id,
              expires_on: expires_on
            }

            case %Credit{} |> Credit.changeset(attrs) |> Repo.insert() do
              {:ok, credit} ->
                credit

              {:error, _changeset} ->
                # Already minted; the partial unique index rejected the insert.
                Repo.one!(
                  from c in Credit,
                    where:
                      c.origin_purchase_id == ^purchase.id and c.seq == ^seq and
                        c.source == "package"
                )
            end
          end)

        {:ok, credits}
    end
  end

  defp earliest_session_date(%Purchase{} = purchase) do
    Repo.one(
      from a in Attendance,
        join: s in Session,
        on: s.id == a.session_id,
        where: a.purchase_id == ^purchase.id,
        select: min(s.date)
    )
  end

  @doc """
  Issues one never-expiring makeup credit per enrolled student on a cancelled
  session. Idempotent via the partial unique index on
  `(origin_session_id, student_id)`.
  """
  def issue_cancellation_credits(%Session{} = session) do
    student_ids =
      Repo.all(
        from a in Attendance,
          where: a.session_id == ^session.id and a.kind == "enrolled",
          select: a.student_id
      )

    credits =
      Enum.map(student_ids, fn student_id ->
        attrs = %{
          student_id: student_id,
          source: "cancellation",
          origin_session_id: session.id,
          expires_on: nil,
          note: session.cancel_reason
        }

        case %Credit{} |> Credit.changeset(attrs) |> Repo.insert() do
          {:ok, credit} ->
            credit

          {:error, _changeset} ->
            Repo.one!(
              from c in Credit,
                where:
                  c.origin_session_id == ^session.id and c.student_id == ^student_id and
                    c.source == "cancellation"
            )
        end
      end)

    {:ok, credits}
  end

  @doc "Credits this student may still spend on a class held on `date`."
  def available_credits(student_id, %Date{} = date) do
    Repo.all(
      from c in Credit,
        where:
          c.student_id == ^student_id and is_nil(c.consumed_by_attendance_id) and
            (is_nil(c.expires_on) or c.expires_on >= ^date),
        order_by: [asc_nulls_last: c.expires_on]
    )
  end

  @doc """
  Books a makeup: creates a free attendance row and spends the credit.

  All three guards must hold — same student, unspent, and not expired on the
  session's date. Wrapped in a transaction so a row is never created without
  its credit being spent, which would silently grant a free class.
  """
  def book_makeup(%Session{} = session, %Student{} = student, %Credit{} = credit) do
    with :ok <- check_owner(credit, student),
         :ok <- check_unconsumed(credit),
         :ok <- check_not_expired(credit, session.date),
         {:ok, attendance} <- insert_makeup(session, student, credit) do
      {:ok, attendance}
    end
  end

  defp insert_makeup(session, student, credit) do
    Repo.transaction(fn ->
      attendance =
        case create_attendance(%{
               session_id: session.id,
               student_id: student.id,
               kind: "makeup",
               purchase_id: nil,
               credit_id: credit.id,
               note: credit.note
             }) do
          {:ok, attendance} -> attendance
          {:error, changeset} -> Repo.rollback(changeset)
        end

      # Compare-and-set, not an unconditional overwrite: two calls racing on
      # the same unreloaded %Credit{} (the brief's own idempotency test needs
      # Repo.reload!/1 before its second attempt to avoid exactly this) must
      # not both succeed in spending it, or one credit buys two makeup classes.
      claim = from(c in Credit, where: c.id == ^credit.id and is_nil(c.consumed_by_attendance_id))
      stamp = DateTime.utc_now() |> DateTime.truncate(:second)

      case Repo.update_all(claim, set: [consumed_by_attendance_id: attendance.id, updated_at: stamp]) do
        {1, _} -> attendance
        {0, _} -> Repo.rollback(:credit_already_consumed)
      end
    end)
  end

  defp check_owner(%Credit{student_id: id}, %Student{id: id}), do: :ok
  defp check_owner(_credit, _student), do: {:error, :credit_not_owned}

  defp check_unconsumed(%Credit{consumed_by_attendance_id: nil}), do: :ok
  defp check_unconsumed(_credit), do: {:error, :credit_already_consumed}

  defp check_not_expired(%Credit{expires_on: nil}, _date), do: :ok

  defp check_not_expired(%Credit{expires_on: expires_on}, %Date{} = date) do
    if Date.compare(expires_on, date) == :lt, do: {:error, :credit_expired}, else: :ok
  end

  @doc "Unspent credits whose expiry has passed, for the Money screen."
  def expired_credits do
    today = Clock.today()

    Repo.all(
      from c in Credit,
        where:
          is_nil(c.consumed_by_attendance_id) and not is_nil(c.expires_on) and
            c.expires_on < ^today,
        order_by: [desc: c.expires_on],
        preload: [:student]
    )
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/roster/credit_test.exs`
Expected: PASS, 12 tests.

- [ ] **Step 7: Run the whole suite**

Run: `mix test`
Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add makeup credits with guarded consumption and idempotent minting"
```

---

### Task 10: Reporting — outstanding balances, revenue, tax threshold

**Files:**
- Create: `lib/ganesha/reporting.ex`
- Test: `test/ganesha/reporting_test.exs`

**Interfaces:**
- Consumes: `Sales.Purchase`, `Sales.Payment`, `Sales.payable/1`, `Roster.Attendance`, `Studio.Session`, `People.list_students/0`.
- Produces: `Reporting.outstanding_for_student/1`, `Reporting.outstanding_by_student/0` (list of `%{student: Student.t(), outstanding: integer}`), `Reporting.revenue_for_month/1`, `Reporting.tax_threshold_status/1` returning `%{revenue: integer, threshold: 50_000, ratio: float, warn?: boolean}`, `Reporting.monthly_threshold/0`, `Reporting.purchase_period/1`.

- [ ] **Step 1: Write the failing test**

`test/ganesha/reporting_test.exs`:

```elixir
defmodule Ganesha.ReportingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Reporting, Roster, Sales, Studio}

  defp monthly_package do
    Catalog.create_package(%{
      name: "月課程-#{System.unique_integer([:positive])}",
      kind: "monthly",
      price_per_class: 400
    })
  end

  # Creates an enrolled August purchase and optionally pays it.
  defp august_sale(paid_amount, opts \\ []) do
    confirm? = Keyword.get(opts, :confirm, true)

    start_time = Time.add(~T[09:30:00], System.unique_integer([:positive]), :second)

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: start_time, end_time: Time.add(start_time, 75, :minute),
        default_style: "基礎", label: "slot-#{System.unique_integer([:positive])}"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "S#{System.unique_integer([:positive])}"})
    {:ok, pkg} = monthly_package()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id, package_id: pkg.id, slot_id: slot.id, list_price: 1600
      })

    for session <- sessions, do: {:ok, _} = Roster.enroll(session, student, purchase)

    if paid_amount > 0 do
      {:ok, payment} =
        Sales.record_payment(%{
          purchase_id: purchase.id, amount: paid_amount,
          method: "line_pay", paid_on: ~D[2026-08-05]
        })

      if confirm?, do: {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    end

    %{student: student, purchase: purchase}
  end

  test "outstanding is payable minus confirmed payments" do
    %{student: student} = august_sale(1200)
    assert Reporting.outstanding_for_student(student.id) == 400
  end

  test "an unconfirmed claim does not reduce what is outstanding" do
    %{student: student} = august_sale(1600, confirm: false)

    assert Reporting.outstanding_for_student(student.id) == 1600,
           "money she has not verified must not count as received"
  end

  test "an override changes what is owed" do
    %{student: student, purchase: purchase} = august_sale(0)
    {:ok, _} = Sales.update_purchase(purchase, %{custom_amount: 0, note: "按摩器代購"})

    assert Reporting.outstanding_for_student(student.id) == 0
  end

  test "outstanding_by_student/0 omits settled students and sorts by amount" do
    %{student: owes_more} = august_sale(0)
    %{student: owes_less} = august_sale(1200)
    %{student: settled} = august_sale(1600)

    rows = Reporting.outstanding_by_student()
    ids = Enum.map(rows, & &1.student.id)

    refute settled.id in ids
    assert ids == [owes_more.id, owes_less.id]
    assert hd(rows).outstanding == 1600
  end

  test "revenue_for_month/1 counts only confirmed payments inside the month" do
    august_sale(1200)
    august_sale(1600, confirm: false)

    assert Reporting.revenue_for_month(~D[2026-08-01]) == 1200
    assert Reporting.revenue_for_month(~D[2026-09-01]) == 0
  end

  test "tax_threshold_status/1 stays quiet at low revenue" do
    august_sale(1200)
    status = Reporting.tax_threshold_status(~D[2026-08-01])

    assert status.threshold == 50_000
    assert status.revenue == 1200
    refute status.warn?
  end

  test "tax_threshold_status/1 warns as the month approaches NT$50,000" do
    for _ <- 1..29, do: august_sale(1600)

    status = Reporting.tax_threshold_status(~D[2026-08-01])

    assert status.revenue == 46_400
    assert status.warn?, "46,400 of 50,000 is past the 90% warning line"
  end

  test "purchase_period/1 spans the first and last attended dates" do
    %{purchase: purchase} = august_sale(1600)

    assert Reporting.purchase_period(purchase.id) == %{
             first: ~D[2026-08-03],
             last: ~D[2026-08-31]
           }
  end

  test "purchase_period/1 is nil for a purchase with no attendance" do
    {:ok, student} = People.create_student(%{display_name: "Nobody"})
    {:ok, pkg} = monthly_package()

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    assert Reporting.purchase_period(purchase.id) == nil
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha/reporting_test.exs`
Expected: FAIL — `Ganesha.Reporting` is undefined.

- [ ] **Step 3: Implement the reporting module**

`lib/ganesha/reporting.ex`:

```elixir
defmodule Ganesha.Reporting do
  @moduledoc """
  Derived numbers: what is owed, what came in, and how close the month is to the
  營業稅 起徵點.

  Purchases have no month column, so any period is reached through the dates of
  their attendance rows. Revenue is the exception: it is keyed on `paid_on`,
  because revenue is about when the money arrived.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Clock
  alias Ganesha.People
  alias Ganesha.Repo
  alias Ganesha.Roster.Attendance
  alias Ganesha.Sales
  alias Ganesha.Sales.{Payment, Purchase}
  alias Ganesha.Studio.Session

  # 營業稅 起徵點 for 勞務 (services) is NT$50,000/month from 114年 onward.
  @monthly_threshold 50_000
  # Warn from 90%, leaving room to react before the cliff. Crossing obliges
  # 稅籍登記, back-assessed to day one of that month if registration is late.
  @warn_ratio 0.9

  def monthly_threshold, do: @monthly_threshold

  @spec outstanding_for_student(integer()) :: integer()
  def outstanding_for_student(student_id) do
    payable =
      Repo.all(from p in Purchase, where: p.student_id == ^student_id)
      |> Enum.map(&Sales.payable/1)
      |> Enum.sum()

    confirmed =
      Repo.one(
        from pay in Payment,
          join: pur in Purchase,
          on: pur.id == pay.purchase_id,
          where: pur.student_id == ^student_id and pay.state == "confirmed",
          select: coalesce(sum(pay.amount), 0)
      )

    payable - confirmed
  end

  @doc "Every student with a positive balance, largest first."
  def outstanding_by_student do
    payable_by_student =
      Repo.all(
        from p in Purchase,
          group_by: p.student_id,
          select: {p.student_id, sum(coalesce(p.custom_amount, p.list_price))}
      )
      |> Map.new()

    confirmed_by_student =
      Repo.all(
        from pay in Payment,
          join: pur in Purchase,
          on: pur.id == pay.purchase_id,
          where: pay.state == "confirmed",
          group_by: pur.student_id,
          select: {pur.student_id, sum(pay.amount)}
      )
      |> Map.new()

    People.list_students()
    |> Enum.map(fn student ->
      payable = Map.get(payable_by_student, student.id, 0)
      confirmed = Map.get(confirmed_by_student, student.id, 0)
      %{student: student, outstanding: payable - confirmed}
    end)
    |> Enum.reject(&(&1.outstanding <= 0))
    |> Enum.sort_by(& &1.outstanding, :desc)
  end

  @spec revenue_for_month(Date.t()) :: integer()
  def revenue_for_month(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Clock.end_of_month(month)

    Repo.one(
      from pay in Payment,
        where: pay.state == "confirmed" and pay.paid_on >= ^first and pay.paid_on <= ^last,
        select: coalesce(sum(pay.amount), 0)
    )
  end

  @doc "Where a month sits against the tax registration threshold."
  def tax_threshold_status(%Date{} = month) do
    revenue = revenue_for_month(month)

    %{
      revenue: revenue,
      threshold: @monthly_threshold,
      ratio: revenue / @monthly_threshold,
      warn?: revenue >= @monthly_threshold * @warn_ratio
    }
  end

  @doc """
  The first and last dates a purchase's attendance rows fall on, for display.
  Returns `nil` when the purchase has no attendance rows yet.
  """
  def purchase_period(purchase_id) do
    case Repo.one(
           from a in Attendance,
             join: s in Session,
             on: s.id == a.session_id,
             where: a.purchase_id == ^purchase_id,
             select: %{first: min(s.date), last: max(s.date)}
         ) do
      %{first: nil, last: nil} -> nil
      period -> period
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/reporting_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add reporting with outstanding balances and tax threshold warning"
```

---

### Task 11: Publishing — the monthly LINE announcement

**Files:**
- Create: `lib/ganesha/publishing.ex`, `lib/ganesha/publishing/settings.ex`
- Create: `priv/repo/migrations/<timestamp>_create_studio_settings.exs`
- Modify: `priv/repo/seeds.exs`
- Test: `test/ganesha/publishing_test.exs`

**Interfaces:**
- Consumes: `Studio.list_active_slots/0`, `Studio.sessions_for_slot_in_month/2`, `Roster.list_for_session/1`, `Catalog.list_active_packages/0`.
- Produces: `%Ganesha.Publishing.Settings{bank_name, bank_code, account_number, transfer_deadline, closing_note}`; `Publishing.get_settings/0`, `Publishing.update_settings/1`, `Publishing.change_settings/2`, `Publishing.schedule_block/1`, `Publishing.signup_block/1`, `Publishing.roster_block/1`, `Publishing.announcement/1`.

- [ ] **Step 1: Generate and fill the migration**

```bash
mix ecto.gen.migration create_studio_settings
```

```elixir
defmodule Ganesha.Repo.Migrations.CreateStudioSettings do
  use Ecto.Migration

  def change do
    # A singleton row. The announcement template lives in code; only the parts
    # she edits live here.
    create table(:studio_settings) do
      add :bank_name, :string
      add :bank_code, :string
      add :account_number, :string
      add :transfer_deadline, :string
      add :closing_note, :text

      timestamps(type: :utc_datetime)
    end
  end
end
```

- [ ] **Step 2: Write the failing test**

`test/ganesha/publishing_test.exs`:

```elixir
defmodule Ganesha.PublishingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Publishing, Roster, Sales, Studio}

  defp august_monday do
    {:ok, _} = Catalog.create_package(%{
      name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1
    })

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {slot, sessions}
  end

  test "schedule_block/1 shows the label, time, dates and package price" do
    august_monday()

    text = Publishing.schedule_block(~D[2026-08-01])

    assert text =~ "8月開課時間表"
    assert text =~ "早晨練習｜週一 基礎瑜伽"
    assert text =~ "9:30－10:45"
    assert text =~ "8/3"
    assert text =~ "8/31"
    # Five Mondays at 400 per class.
    assert text =~ "2000元 /5 堂"
  end

  test "schedule_block/1 marks a session whose style differs from the slot default" do
    {_slot, sessions} = august_monday()
    {:ok, _} = Studio.set_style(Enum.at(sessions, 3), "流動")

    text = Publishing.schedule_block(~D[2026-08-01])

    assert text =~ "*流動8/24", "an overridden style is marked as in her own document"
  end

  test "schedule_block/1 omits cancelled dates" do
    {_slot, sessions} = august_monday()
    {:ok, _} = Studio.cancel_session(hd(sessions), "颱風假")

    text = Publishing.schedule_block(~D[2026-08-01])

    refute text =~ "8/3、"
    assert text =~ "1600元 /4 堂", "the price follows the remaining dates"
  end

  test "signup_block/1 renders numbered places and an 其他 section per slot" do
    august_monday()

    text = Publishing.signup_block(~D[2026-08-01])

    assert text =~ "請寫下姓名"
    assert text =~ "早晨練習｜週一 基礎瑜伽"
    assert text =~ "1."
    assert text =~ "6."
    assert text =~ "其他："
  end

  test "roster_block/1 lists attendees per date and annotates non-enrolled kinds" do
    {slot, sessions} = august_monday()
    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    monthly = hd(Catalog.list_active_packages())

    {:ok, monthly_purchase} =
      Sales.create_purchase(%{
        student_id: lulu.id, package_id: monthly.id, slot_id: slot.id, list_price: 2000
      })

    {:ok, drop_pkg} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, drop_purchase} =
      Sales.create_purchase(%{
        student_id: jennifer.id, package_id: drop_pkg.id, list_price: 450
      })

    session = hd(sessions)
    {:ok, _} = Roster.enroll(session, lulu, monthly_purchase)
    {:ok, _} = Roster.add_drop_in(session, jennifer, drop_purchase)

    text = Publishing.roster_block(~D[2026-08-01])

    assert text =~ "8/3"
    assert text =~ "Lulu"
    assert text =~ "（單）Jennifer"
  end

  test "roster_block/1 marks a no-show" do
    {slot, sessions} = august_monday()
    {:ok, student} = People.create_student(%{display_name: "素容"})
    monthly = hd(Catalog.list_active_packages())

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id, package_id: monthly.id, slot_id: slot.id, list_price: 2000
      })

    {:ok, attendance} = Roster.enroll(hd(sessions), student, purchase)
    {:ok, _} = Roster.mark_no_show(attendance)

    assert Publishing.roster_block(~D[2026-08-01]) =~ "素容（未到）"
  end

  test "roster_block/1 omits a cancelled session, matching schedule_block/1" do
    {_slot, sessions} = august_monday()
    {:ok, _} = Studio.cancel_session(hd(sessions), "颱風假")

    text = Publishing.roster_block(~D[2026-08-01])

    refute text =~ "8/3：", "a cancelled date must not appear in either block"
    assert text =~ "8/10"
  end

  test "roster_block/1 keeps the kind marker on a no-show drop-in" do
    {slot, sessions} = august_monday()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, drop_pkg} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, drop_purchase} =
      Sales.create_purchase(%{student_id: jennifer.id, package_id: drop_pkg.id, list_price: 450})

    {:ok, attendance} = Roster.add_drop_in(hd(sessions), jennifer, drop_purchase)
    {:ok, _} = Roster.mark_no_show(attendance)

    assert Publishing.roster_block(~D[2026-08-01]) =~ "（單）Jennifer（未到）"
  end

  test "announcement/1 renders only the settings fields that are present" do
    august_monday()

    {:ok, _} = Publishing.update_settings(%{account_number: "111001756051"})

    text = Publishing.announcement(~D[2026-08-01])

    refute text =~ "銀行代號", "no bank_code means no bank-name line"
    assert text =~ "帳號： 111001756051"
  end

  test "announcement/1 includes the bank footer from settings" do
    august_monday()

    {:ok, _} =
      Publishing.update_settings(%{
        bank_name: "連線商業銀行",
        bank_code: "824",
        account_number: "111001756051",
        transfer_deadline: "8/15",
        closing_note: "＊＊或者 line pay Money"
      })

    text = Publishing.announcement(~D[2026-08-01])

    assert text =~ "8月開課時間表"
    assert text =~ "請寫下姓名"
    assert text =~ "麻煩於8/15前轉帳，並告知帳後五碼。"
    assert text =~ "824"
    assert text =~ "111001756051"
    assert text =~ "＊＊或者 line pay Money"
  end

  test "announcement/1 omits footer lines that have no settings yet" do
    august_monday()

    text = Publishing.announcement(~D[2026-08-01])

    refute text =~ "麻煩於"
    refute text =~ "銀行代號"
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `mix test test/ganesha/publishing_test.exs`
Expected: FAIL — `Ganesha.Publishing` is undefined.

- [ ] **Step 4: Implement the settings schema**

`lib/ganesha/publishing/settings.ex`:

```elixir
defmodule Ganesha.Publishing.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "studio_settings" do
    field :bank_name, :string
    field :bank_code, :string
    field :account_number, :string
    field :transfer_deadline, :string
    field :closing_note, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    cast(settings, attrs, [
      :bank_name,
      :bank_code,
      :account_number,
      :transfer_deadline,
      :closing_note
    ])
  end
end
```

- [ ] **Step 5: Implement the publishing context**

`lib/ganesha/publishing.ex`:

```elixir
defmodule Ganesha.Publishing do
  @moduledoc """
  Renders the monthly announcement she posts to LINE.

  The output deliberately mirrors the formatting of her hand-written document so
  the message looks unchanged to her students. Nothing here sends anything: a
  push into a 25-person group would cost 25 of the 200 free monthly messages,
  and the bot is not customer-facing. She copies the text and posts it herself.
  """

  import Ecto.Query, warn: false
  alias Ganesha.{Catalog, Repo, Roster, Studio}
  alias Ganesha.Publishing.Settings

  # Blank numbered places in the copy-and-paste signup list.
  @places 6

  def get_settings do
    Repo.one(from s in Settings, limit: 1) || %Settings{}
  end

  def update_settings(attrs) do
    get_settings() |> Settings.changeset(attrs) |> Repo.insert_or_update()
  end

  def change_settings(%Settings{} = settings, attrs \\ %{}) do
    Settings.changeset(settings, attrs)
  end

  @doc "The ✨開課時間表 block: one entry per active slot with its dates and price."
  def schedule_block(%Date{} = month) do
    price = monthly_price_per_class()

    entries =
      Studio.list_active_slots()
      |> Enum.map(&slot_entry(&1, month, price))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    "✨ #{month.month}月開課時間表\n\n" <> entries
  end

  defp slot_entry(slot, month, price) do
    sessions =
      slot
      |> Studio.sessions_for_slot_in_month(month)
      |> Enum.filter(&(&1.state == "scheduled"))

    if sessions == [] do
      nil
    else
      dates = Enum.map_join(sessions, "、", &format_date(&1, slot))
      count = length(sessions)

      String.trim_trailing("""
      #{slot.label}
      時間：#{format_time(slot.start_time)}－#{format_time(slot.end_time)}
      日期：#{dates}
      （#{count * price}元 /#{count} 堂）
      """)
    end
  end

  # A session whose style differs from its slot default is marked with a leading
  # asterisk and the style name, exactly as "*基礎8/26" in her document.
  defp format_date(session, slot) do
    if session.style == slot.default_style do
      short_date(session.date)
    else
      "*#{session.style}#{short_date(session.date)}"
    end
  end

  defp short_date(%Date{} = date), do: "#{date.month}/#{date.day}"

  defp format_time(%Time{} = time) do
    minute = time.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{time.hour}:#{minute}"
  end

  # Slots are published as the monthly package; drop-ins are not advertised.
  defp monthly_price_per_class do
    case Enum.find(Catalog.list_active_packages(), &(&1.kind == "monthly")) do
      nil -> 0
      package -> package.price_per_class
    end
  end

  @doc "The copy-and-paste signup list: numbered places plus an 其他 section."
  def signup_block(%Date{} = _month) do
    intro = "參加月課程的yogi，\n請寫下姓名，\n並複製貼上以便統計。"

    blocks =
      Enum.map_join(Studio.list_active_slots(), "\n\n", fn slot ->
        places = Enum.map_join(1..@places, "\n", &"#{&1}.")
        "#{slot.label}：\n#{places}\n\n其他："
      end)

    intro <> "\n\n" <> blocks
  end

  @doc "Her own reference block: who is on each date, with makeups and drop-ins marked."
  def roster_block(%Date{} = month) do
    Enum.map_join(Studio.list_active_slots(), "\n\n", fn slot ->
      lines =
        slot
        |> Studio.sessions_for_slot_in_month(month)
        |> Enum.filter(&(&1.state == "scheduled"))
        |> Enum.map_join("\n", fn session ->
          names =
            session
            |> Roster.list_for_session()
            |> Enum.map_join("、", &attendee_name/1)

          "#{short_date(session.date)}：#{names}"
        end)

      "#{slot.label}\n#{lines}"
    end)
  end

  # Kind and state are independent: a drop-in or a makeup can also be a
  # no-show, and both markers must survive rather than one short-circuiting
  # the other.
  defp attendee_name(attendance), do: kind_marker(attendance) <> no_show_marker(attendance)

  defp kind_marker(%{kind: "drop_in"} = a), do: "（單）#{a.student.display_name}"
  defp kind_marker(%{kind: "makeup"} = a), do: "#{a.student.display_name}（補課#{note_suffix(a)}）"
  defp kind_marker(%{kind: "trial"} = a), do: "#{a.student.display_name}（體驗）"
  defp kind_marker(a), do: a.student.display_name

  defp no_show_marker(%{state: "no_show"}), do: "（未到）"
  defp no_show_marker(_), do: ""

  defp note_suffix(%{note: nil}), do: ""
  defp note_suffix(%{note: ""}), do: ""
  defp note_suffix(%{note: note}), do: " #{note}"

  @doc "The full message: schedule, signup list, and the transfer footer."
  def announcement(%Date{} = month) do
    settings = get_settings()

    footer =
      [deadline_line(settings), bank_lines(settings), settings.closing_note]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    [schedule_block(month), separator(), signup_block(month)]
    |> then(fn parts -> if footer == "", do: parts, else: parts ++ [separator(), footer] end)
    |> Enum.join("\n\n")
  end

  defp separator, do: "——————————————————"

  defp deadline_line(%Settings{transfer_deadline: nil}), do: nil
  defp deadline_line(%Settings{transfer_deadline: ""}), do: nil

  defp deadline_line(%Settings{transfer_deadline: deadline}) do
    "麻煩於#{deadline}前轉帳，並告知帳後五碼。"
  end

  defp bank_lines(%Settings{} = settings) do
    [bank_line(settings), account_line(settings)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp bank_line(%Settings{bank_code: nil}), do: nil
  defp bank_line(%Settings{bank_code: ""}), do: nil
  defp bank_line(%Settings{} = s), do: String.trim_trailing("LINE Bank 銀行代號：#{s.bank_code} #{s.bank_name}")

  defp account_line(%Settings{account_number: nil}), do: nil
  defp account_line(%Settings{account_number: ""}), do: nil
  defp account_line(%Settings{} = s), do: "帳號： #{s.account_number}"
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix ecto.migrate && mix test test/ganesha/publishing_test.exs`
Expected: PASS, 11 tests.

- [ ] **Step 7: Seed the real bank details**

Append to `priv/repo/seeds.exs`:

```elixir
{:ok, _settings} =
  Ganesha.Publishing.update_settings(%{
    bank_name: "連線商業銀行",
    bank_code: "824",
    account_number: "111001756051",
    transfer_deadline: "每月 15 日",
    closing_note: "＊＊或者 line pay Money"
  })
```

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: generate the monthly LINE announcement from the ledger"
```

---

### Task 12: UI — layout shell and the Today screen

**Files:**
- Modify: `lib/ganesha_web/components/layouts.ex`
- Create: `lib/ganesha_web/live/today_live.ex`
- Modify: `lib/ganesha_web/router.ex`
- Delete: `lib/ganesha_web/controllers/page_controller.ex`, `page_html.ex`, `page_html/home.html.heex`, `test/ganesha_web/controllers/page_controller_test.exs`
- Test: `test/ganesha_web/live/today_live_test.exs`

**Interfaces:**
- Consumes: `Studio.next_session/0`, `Studio.create_session/1`, `Roster.list_for_session/1`, `Roster.get_attendance!/1`, `Roster.mark_no_show/1`, `Roster.mark_expected/1`.
- Produces: route `~p"/"` inside the authenticated `live_session`; `Layouts.bottom_nav/1` used by every later screen, taking `active: :today | :month | :money | :students | :publish`.

- [ ] **Step 1: Write the failing LiveView test**

`test/ganesha_web/live/today_live_test.exs`:

```elixir
defmodule GaneshaWeb.TodayLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp session_today do
    today = Clock.today()

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: Date.day_of_week(today),
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜基礎瑜伽"
      })

    {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: today, style: "基礎"})
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id, package_id: pkg.id, slot_id: slot.id, list_price: 1600
      })

    {:ok, attendance} = Roster.enroll(session, student, purchase)
    %{session: session, attendance: attendance}
  end

  test "shows the next session and its roster", %{conn: conn} do
    %{attendance: attendance} = session_today()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#today-session")
    assert has_element?(view, "#attendance-#{attendance.id}")
  end

  test "toggles a student between expected and no-show", %{conn: conn} do
    %{attendance: attendance} = session_today()

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#no-show-#{attendance.id}") |> render_click()
    assert has_element?(view, "#attendance-#{attendance.id}[data-state=no_show]")

    view |> element("#no-show-#{attendance.id}") |> render_click()
    assert has_element?(view, "#attendance-#{attendance.id}[data-state=expected]")
  end

  test "shows an empty state when nothing is scheduled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#no-upcoming-session")
  end

  test "the bottom navigation is present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#bottom-nav")
    assert has_element?(view, "#nav-money")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/live/today_live_test.exs`
Expected: FAIL — `~p"/"` does not serve a LiveView.

- [ ] **Step 2b: Rewrite the layout shell — remove the Phoenix scaffold header and daisyUI**

`Layouts.app/1` still ships the `phx.new` scaffold: a header linking to
phoenixframework.org, the Phoenix GitHub repo, and hexdocs "Get Started", plus the
Phoenix logo — none of which belong in her app — and it, along with `theme_toggle/1`,
still carries daisyUI classes (`navbar`, `btn btn-ghost`, `btn btn-primary`, `card`,
`border-base-300`, `bg-base-300`, `bg-base-100`, `border-base-200`) even though
daisyUI was removed from `assets/css/app.css` in Task 1. No later task touches this
function, so it is this task's responsibility. Replace both functions in
`lib/ganesha_web/components/layouts.ex` with:

```elixir
  def app(assigns) do
    ~H"""
    <header class="flex items-center justify-end px-4 py-2 sm:px-6">
      <.theme_toggle />
    </header>

    <main class="mx-auto max-w-2xl px-4 pb-4 sm:px-6">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end
```

```elixir
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex items-center rounded-full border border-zinc-300 bg-zinc-100 dark:border-zinc-600 dark:bg-zinc-800">
      <div class="absolute left-0 h-full w-1/3 rounded-full border border-zinc-300 bg-white shadow-sm transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 dark:border-zinc-500 dark:bg-zinc-600" />

      <button class="flex w-1/3 cursor-pointer p-2" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="system">
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button class="flex w-1/3 cursor-pointer p-2" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light">
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button class="flex w-1/3 cursor-pointer p-2" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark">
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
```

`app/1`'s attrs (`flash`, `current_scope`) and `@doc`/`attr` declarations above it are
unchanged — only the two function bodies above change. `current_scope` is unused in
the new body, same as it was in the scaffold's; the user-context/settings/logout row
already lives in `root.html.heex` (translated to Traditional Chinese in Task 2's fix
round) and is out of scope here.

- [ ] **Step 3: Add the bottom navigation to Layouts**

Add to `lib/ganesha_web/components/layouts.ex`:

```elixir
  @doc """
  Thumb-reachable bottom navigation.

  She works on a phone, switching between LINE and this app, so navigation sits
  at the bottom within thumb reach and every target is at least 44px tall.
  """
  attr :active, :atom, required: true

  def bottom_nav(assigns) do
    ~H"""
    <nav
      id="bottom-nav"
      aria-label="主要導覽"
      class="fixed bottom-0 inset-x-0 z-40 flex border-t border-zinc-200 bg-white/95 backdrop-blur
             pb-[env(safe-area-inset-bottom)] dark:border-zinc-800 dark:bg-zinc-900/95"
    >
      <.nav_item active={@active} key={:today} path={~p"/"} icon="hero-sun" label="今天" />
      <.nav_item active={@active} key={:month} path="/month" icon="hero-calendar-days" label="月課表" />
      <.nav_item active={@active} key={:money} path="/money" icon="hero-banknotes" label="收款" />
      <.nav_item active={@active} key={:students} path="/students" icon="hero-users" label="學生" />
      <.nav_item active={@active} key={:publish} path="/publish" icon="hero-share" label="發布" />
    </nav>
    """
  end

  attr :active, :atom, required: true
  attr :key, :atom, required: true
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={"nav-#{@key}"}
      navigate={@path}
      aria-current={@active == @key && "page"}
      class={[
        "flex flex-1 flex-col items-center justify-center gap-1 py-3 min-h-[56px] text-xs",
        @active == @key && "text-emerald-600 dark:text-emerald-400",
        @active != @key && "text-zinc-500 dark:text-zinc-400"
      ]}
    >
      <.icon name={@icon} class="w-6 h-6" />
      {@label}
    </.link>
    """
  end
```

- [ ] **Step 4: Implement TodayLive**

`lib/ganesha_web/live/today_live.ex`:

```elixir
defmodule GaneshaWeb.TodayLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Roster, Studio}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  defp load(socket) do
    case Studio.next_session() do
      nil ->
        socket
        |> assign(:session, nil)
        |> stream(:attendances, [], reset: true, dom_id: &"attendance-#{&1.id}")

      session ->
        socket
        |> assign(:session, session)
        |> stream(:attendances, Roster.list_for_session(session),
          reset: true,
          dom_id: &"attendance-#{&1.id}"
        )
    end
  end

  @impl true
  def handle_event("toggle_no_show", %{"id" => id}, socket) do
    attendance = Roster.get_attendance!(id)

    {:ok, _updated} =
      case attendance.state do
        "expected" -> Roster.mark_no_show(attendance)
        "no_show" -> Roster.mark_expected(attendance)
      end

    # get_attendance!/1 preloads [:student, session: :slot], which does not
    # match the [:student, purchase: :package] shape every other row in this
    # stream has (from list_for_session/1). Re-derive the row through that
    # same accessor so the stream never mixes preload shapes across rows.
    refreshed =
      socket.assigns.session
      |> Roster.list_for_session()
      |> Enum.find(&(&1.id == attendance.id))

    {:noreply, stream_insert(socket, :attendances, refreshed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <%= if @session do %>
          <section id="today-session" class="rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800">
            <h1 class="text-lg font-semibold">{@session.slot.label}</h1>
            <p class="mt-1 text-sm text-zinc-500">{@session.date} · {@session.style}</p>
          </section>

          <ul id="attendances" phx-update="stream" class="mt-4 space-y-2">
            <li
              :for={{dom_id, attendance} <- @streams.attendances}
              id={dom_id}
              data-state={attendance.state}
              class="flex items-center justify-between rounded-xl border border-zinc-200 p-3 dark:border-zinc-800"
            >
              <span class={[
                "text-base",
                attendance.state == "no_show" && "line-through text-zinc-400"
              ]}>
                {attendance.student.display_name}
              </span>
              <button
                id={"no-show-#{attendance.id}"}
                phx-click="toggle_no_show"
                phx-value-id={attendance.id}
                class="min-h-[44px] min-w-[44px] rounded-lg px-3 text-sm text-zinc-600 hover:bg-zinc-100
                       dark:text-zinc-300 dark:hover:bg-zinc-800"
              >
                {if attendance.state == "no_show", do: "已到", else: "未到"}
              </button>
            </li>
          </ul>
        <% else %>
          <p
            id="no-upcoming-session"
            class="rounded-2xl border border-dashed border-zinc-300 p-8 text-center text-zinc-500 dark:border-zinc-700"
          >
            目前沒有排定的課程
          </p>
        <% end %>
      </div>

      <Layouts.bottom_nav active={:today} />
    </Layouts.app>
    """
  end
end
```

Note the DOM id: `stream/4`'s `dom_id:` option (used in `load/1` above) makes the
stream itself produce `id="attendance-<id>"`, matching the test's `#attendance-<id>`
selector, so `id={dom_id}` on the `<li>` needs no further override. Do not hardcode
the `<li>` id separately — that disconnects the row from LiveView's stream-ref
bookkeeping (`reset`, `stream_delete`, and `:at` positional inserts all key off the
element actually carrying `data-phx-stream`, which only the stream's own dom id gets).

- [ ] **Step 5: Add the route and remove the scaffold page**

In `lib/ganesha_web/router.ex`, inside the authenticated `live_session` block, add:

```elixir
      live "/", TodayLive, :index
```

Remove the `get "/", PageController, :home` route, then:

```bash
rm -f lib/ganesha_web/controllers/page_controller.ex \
      lib/ganesha_web/controllers/page_html.ex \
      lib/ganesha_web/controllers/page_html/home.html.heex \
      test/ganesha_web/controllers/page_controller_test.exs
rmdir lib/ganesha_web/controllers/page_html 2>/dev/null || true
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/today_live_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add phone-first layout shell and Today roster screen"
```

---

### Task 13: UI — the month screen

**Files:**
- Create: `lib/ganesha_web/live/month_live.ex`
- Modify: `lib/ganesha_web/router.ex`
- Test: `test/ganesha_web/live/month_live_test.exs`

**Interfaces:**
- Consumes: `Studio.list_active_slots/0`, `Studio.sessions_for_slot_in_month/2`, `Studio.generate_month/2`, `Studio.get_slot!/1`, `Studio.get_session!/1`, `Studio.set_style/2`, `Studio.cancel_session/2`, `Roster.issue_cancellation_credits/1`, `Ganesha.Clock.today/0`.
- Produces: routes `~p"/month"` and `~p"/month/:year/:month"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha_web/live/month_live_test.exs`:

```elixir
defmodule GaneshaWeb.MonthLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp monday_slot do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    slot
  end

  test "generates a month's sessions on demand", %{conn: conn} do
    slot = monday_slot()

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    view |> element("#generate-slot-#{slot.id}") |> render_click()

    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01])) == 5
    assert has_element?(view, "#slot-#{slot.id}")
    assert has_element?(view, "[data-date='2026-08-03']")
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
        student_id: student.id, package_id: pkg.id, slot_id: slot.id, list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    view
    |> form("#cancel-form-#{session.id}", %{"reason" => "颱風假"})
    |> render_submit()

    assert Studio.get_session!(session.id).state == "cancelled"

    # A cancellation credit never expires, so it is available far in the future.
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
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/live/month_live_test.exs`
Expected: FAIL — no route matches `/month/2026/8`.

- [ ] **Step 3: Implement MonthLive**

`lib/ganesha_web/live/month_live.ex`:

```elixir
defmodule GaneshaWeb.MonthLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Repo, Roster, Studio}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_month(params) |> load_slots()}
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

  defp load_slots(socket) do
    month = socket.assigns.month

    slots =
      Enum.map(Studio.list_active_slots(), fn slot ->
        %{slot: slot, sessions: Studio.sessions_for_slot_in_month(slot, month)}
      end)

    assign(socket, :slots, slots)
  end

  @impl true
  def handle_event("generate", %{"slot-id" => slot_id}, socket) do
    {:ok, _sessions} =
      slot_id |> Studio.get_slot!() |> Studio.generate_month(socket.assigns.month)

    {:noreply, socket |> put_flash(:info, "已建立本月課程") |> load_slots()}
  end

  def handle_event("set_style", %{"session-id" => id, "style" => style}, socket) do
    {:ok, _session} = id |> Studio.get_session!() |> Studio.set_style(style)

    {:noreply, socket |> put_flash(:info, "已更新課型") |> load_slots()}
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
         |> load_slots()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請填寫停課原因")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@month.year} 年 {@month.month} 月課表</h1>

        <section
          :for={%{slot: slot, sessions: sessions} <- @slots}
          id={"slot-#{slot.id}"}
          class="mt-4 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <header class="flex items-start justify-between gap-3">
            <h2 class="font-medium">{slot.label}</h2>
            <button
              :if={sessions == []}
              id={"generate-slot-#{slot.id}"}
              phx-click="generate"
              phx-value-slot-id={slot.id}
              class="min-h-[44px] rounded-lg bg-emerald-600 px-3 text-sm text-white"
            >
              建立本月
            </button>
          </header>

          <ul class="mt-3 space-y-3">
            <li
              :for={session <- sessions}
              data-date={session.date}
              class="rounded-xl border border-zinc-200 p-3 dark:border-zinc-800"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-mono text-sm">{session.date}</span>
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs",
                  session.state == "cancelled" && "bg-red-100 text-red-700",
                  session.state == "scheduled" && "bg-zinc-100 text-zinc-600"
                ]}>
                  <%= if session.state == "cancelled" do %>
                    已停課 · {session.cancel_reason}
                  <% else %>
                    {session.style}
                  <% end %>
                </span>
              </div>

              <div :if={session.state == "scheduled"} class="mt-2 flex flex-wrap gap-2">
                <form id={"style-form-#{session.id}"} phx-submit="set_style" class="flex gap-2">
                  <input type="hidden" name="session-id" value={session.id} />
                  <input
                    type="text"
                    name="style"
                    value={session.style}
                    required
                    class="min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
                  />
                  <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
                    改課型
                  </button>
                </form>

                <form id={"cancel-form-#{session.id}"} phx-submit="cancel" class="flex gap-2">
                  <input type="hidden" name="session-id" value={session.id} />
                  <input
                    type="text"
                    name="reason"
                    placeholder="停課原因"
                    class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
                  />
                  <button class="min-h-[44px] rounded-lg border border-red-300 px-3 text-sm text-red-700">
                    停課
                  </button>
                </form>
              </div>
            </li>
          </ul>
        </section>
      </div>

      <Layouts.bottom_nav active={:month} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Add the routes**

Inside the authenticated `live_session`:

```elixir
      live "/month", MonthLive, :index
      live "/month/:year/:month", MonthLive, :index
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/month_live_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add month screen with style override and cancellation credits"
```

---

### Task 14: UI — students, purchases, and payment confirmation

**Files:**
- Create: `lib/ganesha_web/live/student_live/index.ex`, `lib/ganesha_web/live/student_live/show.ex`
- Modify: `lib/ganesha_web/router.ex`
- Test: `test/ganesha_web/live/student_live_test.exs`

**Interfaces:**
- Consumes: `People.list_students/0`, `People.create_student/1`, `People.change_student/2`, `People.get_student!/1`, `Sales.list_purchases_for_student/1`, `Sales.get_purchase!/1`, `Sales.update_purchase/2`, `Sales.payable/1`, `Sales.list_payments_for_purchase/1`, `Sales.confirm_payment/2`, `Sales.suspicious_last5?/1`, `Reporting.outstanding_for_student/1`, `Roster.available_credits/2`.
- Produces: routes `~p"/students"` and `~p"/students/:id"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha_web/live/student_live_test.exs`:

```elixir
defmodule GaneshaWeb.StudentLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Repo, Sales}

  setup :register_and_log_in_user

  defp student_with_purchase do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    %{student: student, purchase: purchase}
  end

  test "lists students", %{conn: conn} do
    %{student: student} = student_with_purchase()

    {:ok, view, _html} = live(conn, ~p"/students")
    assert has_element?(view, "#student-#{student.id}")
  end

  test "creates a student", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/students")

    view
    |> form("#student-form", %{"student" => %{"display_name" => "Carita"}})
    |> render_submit()

    assert render(view) =~ "Carita"
  end

  test "shows purchases and the outstanding balance", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    assert has_element?(view, "#purchase-#{purchase.id}")
    assert has_element?(view, "#outstanding")
    assert render(view) =~ "1600"
  end

  test "confirming a payment records the confirmer and clears the balance", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id, amount: 1600, method: "line_pay", paid_on: Clock.today()
      })

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    view |> element("#confirm-payment-#{payment.id}") |> render_click()

    confirmed = Repo.reload!(payment)
    assert confirmed.state == "confirmed"
    refute is_nil(confirmed.confirmed_by)
    refute is_nil(confirmed.confirmed_at)

    assert has_element?(view, "#outstanding[data-amount='0']")
  end

  test "records a custom amount override with a note", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    view
    |> form("#override-form-#{purchase.id}", %{
      "custom_amount" => "0",
      "note" => "按摩器代購"
    })
    |> render_submit()

    updated = Repo.reload!(purchase)
    assert updated.custom_amount == 0
    assert updated.note == "按摩器代購"
    assert has_element?(view, "#outstanding[data-amount='0']")
  end

  test "clearing the override field restores the list price", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()
    {:ok, _} = Sales.update_purchase(purchase, %{custom_amount: 0})

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    view
    |> form("#override-form-#{purchase.id}", %{"custom_amount" => "", "note" => ""})
    |> render_submit()

    assert is_nil(Repo.reload!(purchase).custom_amount)
    assert has_element?(view, "#outstanding[data-amount='1600']")
  end

  test "flags a suspicious repeated last5 on the same purchase", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()
    today = Clock.today()

    for _ <- 1..2 do
      {:ok, _} =
        Sales.record_payment(%{
          purchase_id: purchase.id, amount: 1600, method: "line_pay",
          paid_on: today, reported_last5: "99999"
        })
    end

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    assert has_element?(view, "[data-suspicious=true]")
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/live/student_live_test.exs`
Expected: FAIL — no route matches `/students`.

- [ ] **Step 3: Implement the index LiveView**

`lib/ganesha_web/live/student_live/index.ex`:

```elixir
defmodule GaneshaWeb.StudentLive.Index do
  use GaneshaWeb, :live_view

  alias Ganesha.People
  alias Ganesha.People.Student

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(People.change_student(%Student{})))
     |> stream(:students, People.list_students(), dom_id: &"student-#{&1.id}")}
  end

  @impl true
  def handle_event("save", %{"student" => params}, socket) do
    case People.create_student(params) do
      {:ok, student} ->
        {:noreply,
         socket
         |> stream_insert(:students, student, at: 0)
         |> assign(:form, to_form(People.change_student(%Student{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">學生</h1>

        <.form for={@form} id="student-form" phx-submit="save" class="mt-3 flex items-end gap-2">
          <.input field={@form[:display_name]} type="text" placeholder="姓名" />
          <button class="min-h-[44px] rounded-lg bg-emerald-600 px-4 text-sm text-white">新增</button>
        </.form>

        <ul id="students" phx-update="stream" class="mt-4 space-y-2">
          <li :for={{dom_id, student} <- @streams.students} id={dom_id}>
            <.link
              navigate={~p"/students/#{student.id}"}
              class="flex min-h-[56px] items-center justify-between rounded-xl border border-zinc-200 px-4 dark:border-zinc-800"
            >
              <span>{student.display_name}</span>
              <.icon name="hero-chevron-right" class="w-5 h-5 text-zinc-400" />
            </.link>
          </li>
        </ul>
      </div>

      <Layouts.bottom_nav active={:students} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Implement the show LiveView**

`lib/ganesha_web/live/student_live/show.ex`:

```elixir
defmodule GaneshaWeb.StudentLive.Show do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, People, Reporting, Repo, Roster, Sales}
  alias Ganesha.Sales.Payment

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, socket |> assign(:student, People.get_student!(id)) |> load()}
  end

  defp load(socket) do
    student = socket.assigns.student
    purchases = Sales.list_purchases_for_student(student.id)

    payments =
      Map.new(purchases, fn purchase ->
        rows =
          purchase.id
          |> Sales.list_payments_for_purchase()
          |> Enum.map(&%{payment: &1, suspicious?: Sales.suspicious_last5?(&1)})

        {purchase.id, rows}
      end)

    socket
    |> assign(:purchases, purchases)
    |> assign(:payments, payments)
    |> assign(:outstanding, Reporting.outstanding_for_student(student.id))
    |> assign(:credits, Roster.available_credits(student.id, Clock.today()))
  end

  @impl true
  def handle_event("confirm_payment", %{"id" => id}, socket) do
    payment = Repo.get!(Payment, id)
    # The confirmer is the logged-in teacher: confirmation is a human assertion
    # that the money arrived, and the schema records who made it.
    {:ok, _} = Sales.confirm_payment(payment, socket.assigns.current_scope.user.email)

    {:noreply, socket |> put_flash(:info, "已確認收款") |> load()}
  end

  def handle_event("override", %{"purchase-id" => id} = params, socket) do
    purchase = Sales.get_purchase!(id)

    attrs = %{
      custom_amount: blank_to_nil(params["custom_amount"]),
      note: blank_to_nil(params["note"])
    }

    {:ok, _} = Sales.update_purchase(purchase, attrs)

    {:noreply, socket |> put_flash(:info, "已更新金額") |> load()}
  end

  # An empty field means "no override", which must become NULL rather than 0.
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@student.display_name}</h1>

        <p id="outstanding" data-amount={@outstanding} class="mt-1 text-sm text-zinc-500">
          未收：NT$ {@outstanding}
        </p>

        <section
          :if={@credits != []}
          class="mt-4 rounded-2xl border border-purple-200 p-4 dark:border-purple-900"
        >
          <h2 class="text-sm font-medium">可用補課額度：{length(@credits)}</h2>
          <ul class="mt-2 space-y-1 text-xs text-zinc-500">
            <li :for={credit <- @credits}>
              {credit.source} ·
              <%= if credit.expires_on do %>
                至 {credit.expires_on}
              <% else %>
                無期限
              <% end %>
            </li>
          </ul>
        </section>

        <section
          :for={purchase <- @purchases}
          id={"purchase-#{purchase.id}"}
          class="mt-4 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <header class="flex items-baseline justify-between gap-2">
            <h2 class="font-medium">{purchase.package.name}</h2>
            <span class="font-mono text-sm">NT$ {Sales.payable(purchase)}</span>
          </header>

          <p :if={purchase.custom_amount} class="mt-1 text-xs text-zinc-500">
            原價 {purchase.list_price}<span :if={purchase.note}> · {purchase.note}</span>
          </p>

          <form id={"override-form-#{purchase.id}"} phx-submit="override" class="mt-3 flex flex-wrap gap-2">
            <input type="hidden" name="purchase-id" value={purchase.id} />
            <input
              type="number"
              name="custom_amount"
              value={purchase.custom_amount}
              placeholder="自訂金額"
              class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="text"
              name="note"
              value={purchase.note}
              placeholder="備註"
              class="min-h-[44px] w-32 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              儲存
            </button>
          </form>

          <ul class="mt-3 space-y-2">
            <li
              :for={%{payment: payment, suspicious?: suspicious?} <- @payments[purchase.id] || []}
              data-suspicious={to_string(suspicious?)}
              class="flex items-center justify-between gap-2 text-sm"
            >
              <span>
                NT$ {payment.amount} · {payment.method}
                <span :if={payment.reported_last5} class="text-zinc-400">
                  ({payment.reported_last5})
                </span>
                <span :if={suspicious?} class="text-amber-600">重複？</span>
              </span>

              <button
                :if={payment.state == "claimed"}
                id={"confirm-payment-#{payment.id}"}
                phx-click="confirm_payment"
                phx-value-id={payment.id}
                class="min-h-[44px] rounded-lg bg-emerald-600 px-3 text-xs text-white"
              >
                確認入帳
              </button>
              <span :if={payment.state == "confirmed"} class="text-xs text-emerald-600">已確認</span>
              <span :if={payment.state == "disputed"} class="text-xs text-red-600">有問題</span>
            </li>
          </ul>
        </section>
      </div>

      <Layouts.bottom_nav active={:students} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Add the routes**

```elixir
      live "/students", StudentLive.Index, :index
      live "/students/:id", StudentLive.Show, :show
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/student_live_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add student screens with payment confirmation and amount override"
```

---

### Task 15: UI — the Money screen and the Publish screen

**Files:**
- Create: `lib/ganesha_web/live/money_live.ex`, `lib/ganesha_web/live/publish_live.ex`
- Modify: `lib/ganesha_web/router.ex`
- Test: `test/ganesha_web/live/money_live_test.exs`, `test/ganesha_web/live/publish_live_test.exs`

**Interfaces:**
- Consumes: `Reporting.outstanding_by_student/0`, `Reporting.revenue_for_month/1`, `Reporting.tax_threshold_status/1`, `Roster.expired_credits/0`, `Publishing.announcement/1`, `Publishing.roster_block/1`.
- Produces: routes `~p"/money"`, `~p"/publish"`, `~p"/publish/:year/:month"`; a `.CopyText` colocated hook.

- [ ] **Step 1: Write the failing tests**

`test/ganesha_web/live/money_live_test.exs`:

```elixir
defmodule GaneshaWeb.MoneyLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Sales}

  setup :register_and_log_in_user

  defp confirmed_sale(amount) do
    {:ok, student} = People.create_student(%{display_name: "S#{System.unique_integer([:positive])}"})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "pkg-#{System.unique_integer([:positive])}",
        kind: "monthly", price_per_class: 400
      })

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: amount})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id, amount: amount, method: "line_pay", paid_on: Clock.today()
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    student
  end

  test "lists students who still owe money and shows the revenue gauge", %{conn: conn} do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    {:ok, view, _html} = live(conn, ~p"/money")

    assert has_element?(view, "#owing-#{student.id}")
    assert has_element?(view, "#revenue")
    assert has_element?(view, "#tax-gauge")
  end

  test "shows a settled state when nothing is owed", %{conn: conn} do
    _student = confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#nothing-owed")
  end

  test "stays quiet about the tax threshold at low revenue", %{conn: conn} do
    _student = confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    refute has_element?(view, "#tax-warning")
  end

  test "warns when the month approaches NT$50,000", %{conn: conn} do
    for _ <- 1..29, do: confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#tax-warning")
  end
end
```

`test/ganesha_web/live/publish_live_test.exs`:

```elixir
defmodule GaneshaWeb.PublishLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Studio}

  setup :register_and_log_in_user

  test "renders the announcement text and a copy button", %{conn: conn} do
    {:ok, _} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/publish/2026/8")

    assert has_element?(view, "#announcement-text")
    assert has_element?(view, "#copy-announcement")
    assert render(view) =~ "早晨練習｜週一 基礎瑜伽"
    assert render(view) =~ "8月開課時間表"
  end

  test "shows the roster block for her own reference", %{conn: conn} do
    {:ok, _} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/publish/2026/8")
    assert has_element?(view, "#roster-text")
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test test/ganesha_web/live/money_live_test.exs test/ganesha_web/live/publish_live_test.exs`
Expected: FAIL — no routes for `/money` or `/publish/2026/8`.

- [ ] **Step 3: Implement MoneyLive**

`lib/ganesha_web/live/money_live.ex`:

```elixir
defmodule GaneshaWeb.MoneyLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Reporting, Roster}

  @impl true
  def mount(_params, _session, socket) do
    month = Date.beginning_of_month(Clock.today())

    {:ok,
     socket
     |> assign(:month, month)
     |> assign(:owing, Reporting.outstanding_by_student())
     |> assign(:revenue, Reporting.revenue_for_month(month))
     |> assign(:tax, Reporting.tax_threshold_status(month))
     |> assign(:expired_credits, Roster.expired_credits())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">收款</h1>

        <section class="mt-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800">
          <p id="revenue" data-amount={@revenue} class="text-2xl font-semibold tabular-nums">
            NT$ {@revenue}
          </p>
          <p class="text-xs text-zinc-500">{@month.year} 年 {@month.month} 月已確認收入</p>

          <div
            id="tax-gauge"
            class="mt-3 h-2 overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800"
          >
            <div
              class={[
                "h-full rounded-full transition-all",
                @tax.warn? && "bg-amber-500",
                !@tax.warn? && "bg-emerald-500"
              ]}
              style={"width: #{min(@tax.ratio, 1.0) * 100}%"}
            />
          </div>

          <p class="mt-1 text-xs text-zinc-500">營業稅起徵點 NT$ {@tax.threshold} / 月（勞務）</p>

          <p
            :if={@tax.warn?}
            id="tax-warning"
            class="mt-2 rounded-lg bg-amber-50 p-2 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-200"
          >
            本月接近起徵點。超過當月即須辦理稅籍登記，逾期會自當月一日起補徵。
          </p>
        </section>

        <section class="mt-4">
          <h2 class="text-sm font-medium text-zinc-500">未收款</h2>
          <ul class="mt-2 space-y-2">
            <li
              :for={row <- @owing}
              id={"owing-#{row.student.id}"}
              class="flex min-h-[56px] items-center justify-between rounded-xl border border-zinc-200 px-4 dark:border-zinc-800"
            >
              <.link navigate={~p"/students/#{row.student.id}"}>{row.student.display_name}</.link>
              <span class="font-mono text-sm">NT$ {row.outstanding}</span>
            </li>
            <li :if={@owing == []} id="nothing-owed" class="text-sm text-zinc-400">全部收齊</li>
          </ul>
        </section>

        <section :if={@expired_credits != []} class="mt-4">
          <h2 class="text-sm font-medium text-zinc-500">已過期補課額度</h2>
          <ul class="mt-2 space-y-1 text-xs text-zinc-500">
            <li :for={credit <- @expired_credits}>
              {credit.student.display_name} · 到期 {credit.expires_on}
            </li>
          </ul>
        </section>
      </div>

      <Layouts.bottom_nav active={:money} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Implement PublishLive with a colocated copy hook**

`lib/ganesha_web/live/publish_live.ex`:

```elixir
defmodule GaneshaWeb.PublishLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Publishing}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_month(socket, params)}
  end

  defp assign_month(socket, %{"year" => year, "month" => month}) do
    with {y, ""} <- Integer.parse(year),
         {m, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(y, m, 1) do
      put_month(socket, date)
    else
      _ -> assign_month(socket, %{})
    end
  end

  defp assign_month(socket, _params) do
    put_month(socket, Date.beginning_of_month(Clock.today()))
  end

  defp put_month(socket, %Date{} = month) do
    socket
    |> assign(:month, month)
    |> assign(:announcement, Publishing.announcement(month))
    |> assign(:roster, Publishing.roster_block(month))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <div class="flex items-center justify-between gap-2">
          <h1 class="text-lg font-semibold">{@month.month} 月公告</h1>
          <button
            id="copy-announcement"
            phx-hook=".CopyText"
            data-target="announcement-text"
            class="min-h-[44px] rounded-lg bg-emerald-600 px-4 text-sm text-white"
          >
            複製
          </button>
        </div>

        <pre
          id="announcement-text"
          phx-no-curly-interpolation
          class="mt-3 whitespace-pre-wrap rounded-2xl border border-zinc-200 p-4 text-sm leading-relaxed dark:border-zinc-800"
        ><%= @announcement %></pre>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">名單（自用）</h2>
        <pre
          id="roster-text"
          phx-no-curly-interpolation
          class="mt-2 whitespace-pre-wrap rounded-2xl border border-zinc-200 p-4 text-sm leading-relaxed dark:border-zinc-800"
        ><%= @roster %></pre>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const source = document.getElementById(this.el.dataset.target)
              if (!source) return
              const original = this.el.textContent
              try {
                await navigator.clipboard.writeText(source.innerText)
                this.el.textContent = "已複製"
                setTimeout(() => { this.el.textContent = original }, 1500)
              } catch (_error) {
                // Clipboard permission can be denied; select the text instead so
                // she can still copy it with a long press.
                const range = document.createRange()
                range.selectNodeContents(source)
                const selection = window.getSelection()
                selection.removeAllRanges()
                selection.addRange(range)
              }
            })
          }
        }
      </script>

      <Layouts.bottom_nav active={:publish} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 5: Add the routes**

```elixir
      live "/money", MoneyLive, :index
      live "/publish", PublishLive, :index
      live "/publish/:year/:month", PublishLive, :index
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/money_live_test.exs test/ganesha_web/live/publish_live_test.exs`
Expected: PASS, 6 tests.

- [ ] **Step 7: Verify the copy hook in a real browser**

Run `mix phx.server`, log in, open `/publish`, and tap 複製. The button must read 已複製 and the clipboard must contain the announcement. A colocated hook that never mounts fails silently, so this cannot be left to the test suite.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add money screen with tax gauge and publish screen with copy hook"
```

---

### Task 16: Deployment — Fly.io, Litestream, health check

**Files:**
- Create: `lib/ganesha_web/controllers/health_controller.ex`
- Create (generated): `Dockerfile`, `.dockerignore`, `rel/`
- Modify (generated): `rel/overlays/bin/server` (migrate-on-boot), `Dockerfile` (Litestream + volume-ownership entrypoint)
- Create: `fly.toml`, `litestream.yml`, `rel/overlays/bin/docker-entrypoint.sh`
- Modify: `config/runtime.exs`, `config/prod.exs`, `lib/ganesha_web/router.ex`
- Test: `test/ganesha_web/health_test.exs`

**Interfaces:**
- Consumes: everything.
- Produces: `GET /health` returning `"ok"`; a deployable release.

- [ ] **Step 1: Write the failing health test**

`test/ganesha_web/health_test.exs`:

```elixir
defmodule GaneshaWeb.HealthTest do
  use GaneshaWeb.ConnCase, async: true

  test "the health endpoint is public and returns ok", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert response(conn, 200) == "ok"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/health_test.exs`
Expected: FAIL — no route matches `/health`.

- [ ] **Step 3: Add the health controller and route**

`lib/ganesha_web/controllers/health_controller.ex`:

```elixir
defmodule GaneshaWeb.HealthController do
  use GaneshaWeb, :controller

  @doc """
  Unauthenticated liveness+readiness probe for the platform health check.

  Touches the database rather than answering unconditionally: a machine
  whose volume failed to mount or whose SQLite file is unwritable would
  otherwise report healthy while every real page 500s, and Fly would keep
  routing traffic to it instead of rolling the deploy back.
  """
  def index(conn, _params) do
    Ganesha.Repo.query!("select 1")
    send_resp(conn, 200, "ok")
  end
end
```

In `lib/ganesha_web/router.ex`, in a scope that is NOT behind authentication:

```elixir
  scope "/", GaneshaWeb do
    pipe_through :browser

    get "/health", HealthController, :index
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/ganesha_web/health_test.exs`
Expected: PASS.

- [ ] **Step 4b: Exclude `/health` from `force_ssl`**

Fly's `[[http_service.checks]]` (Step 8) hit the app directly over plain HTTP on
the machine's internal port — they never pass through the Fly proxy, so no
`x-forwarded-proto: https` header is added and the request's Host is the
machine's private address, not `localhost`/`127.0.0.1`. Without an exclusion,
`Plug.SSL` 301-redirects `/health` to `https://`, which Fly's checker does not
follow, and the machine never becomes healthy.

In `config/prod.exs`, uncomment the generator's own hint so the `exclude:` list
reads:

```elixir
config :ganesha, GaneshaWeb.Endpoint,
  force_ssl: [
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      paths: ["/health"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]
```

`:force_ssl` is compile-time config and must be changed here, not in
`runtime.exs`.

- [ ] **Step 5: Generate the release scaffolding**

```bash
mix phx.gen.release --docker
```

- [ ] **Step 5b: Migrate on boot**

`mix phx.gen.release --docker` writes `rel/overlays/bin/server` as a thin
wrapper that only starts the release. Nothing in this deployment runs
migrations automatically otherwise — the `[deploy] release_command` pattern is
wrong here because Fly's release-command machine does not mount the app's
volume, so it would migrate an ephemeral file instead of the real database.
Migrating on the boot path is safe specifically because exactly one machine
ever owns the SQLite file (Step 8's `min_machines_running = 1`).

Edit `rel/overlays/bin/server` to:

```sh
#!/bin/sh
set -eu

cd -P -- "$(dirname -- "$0")"

# Exactly one machine owns the SQLite file (see fly.toml's
# min_machines_running = 1), so migrating on boot is safe here in a way it
# would not be with a horizontally-scaled release_command.
./ganesha eval Ganesha.Release.migrate
PHX_SERVER=true exec ./ganesha start
```

- [ ] **Step 6: Point the production database at the mounted volume**

In `config/runtime.exs`, inside `if config_env() == :prod do`, replace the repo configuration with:

```elixir
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise "DATABASE_PATH is not set (expected a path on the mounted volume)"

  config :ganesha, Ganesha.Repo,
    database: database_path,
    pool_size: 5,
    # One machine owns this file, so there is no second writer to coordinate
    # with; a busy timeout is enough.
    busy_timeout: 5_000
```

- [ ] **Step 7: Add `litestream.yml`**

```yaml
# Continuous replication of the SQLite database.
# A nightly dump would leave a 24-hour RPO on payment records, which is not
# acceptable when the alternative is one sidecar process.
dbs:
  - path: ${DATABASE_PATH}
    replicas:
      - type: s3
        endpoint: ${LITESTREAM_ENDPOINT}
        bucket: ${LITESTREAM_BUCKET}
        path: ganesha
        access-key-id: ${LITESTREAM_ACCESS_KEY_ID}
        secret-access-key: ${LITESTREAM_SECRET_ACCESS_KEY}
```

- [ ] **Step 8: Add `fly.toml`**

```toml
app = "ganesha"
# nrt is the closest Fly region to Taiwan. Every interaction is a phone tap
# against a LiveView socket, so round-trip latency is felt directly.
primary_region = "nrt"

[build]

[env]
  PHX_HOST = "ganesha.fly.dev"
  PORT = "8080"
  DATABASE_PATH = "/data/ganesha.db"

[[mounts]]
  source = "ganesha_data"
  destination = "/data"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = false
  auto_start_machines = true
  # A single machine owns the SQLite file. Never scale this to two.
  min_machines_running = 1

[[http_service.checks]]
  interval = "30s"
  timeout = "5s"
  method = "get"
  path = "/health"

[[vm]]
  size = "shared-cpu-1x"
  memory = "512mb"
```

- [ ] **Step 8b: Fix volume ownership and wire Litestream into the image**

Two problems with the Dockerfile as generated, both real and both reachable
on the very first deploy:

1. **Volume ownership.** The runner stage does `USER nobody` after `RUN chown
   nobody /app`, but `/data` is a Fly volume mounted at container start, not
   part of the image — a freshly created volume is `root:root`. The release
   (and `rel/overlays/bin/server`'s migrate-on-boot call) opens
   `${DATABASE_PATH}` as `nobody` and fails with `EACCES` before the endpoint
   ever starts.
2. **Litestream is inert.** `litestream.yml` (Step 7) is never copied into the
   image, no `litestream` binary is installed, and `CMD` starts only the
   release. The continuous-replication goal stated in `litestream.yml`'s own
   header is not achieved by anything in the repo as generated.

Fix both together with a root entrypoint that fixes ownership once, then drops
privilege — and that only wraps the release in `litestream replicate` when a
replica is actually configured, rather than unconditionally. **Litestream
fails closed, not open**: with `type: s3` and an empty `bucket`, it exits
non-zero before `-exec` ever runs the wrapped command (verified against the
real binary: `bucket required for s3 replica`, exit 1). An unconditional
wrapper means the app cannot boot at all — not degraded, not unreplicated,
*down* — the moment `LITESTREAM_BUCKET` and friends aren't set, which is true
of a fresh deploy before those secrets are configured and of every local/dev
container run.

`rel/overlays/bin/docker-entrypoint.sh` (new file; `mix release`'s overlay
mechanism ships anything under `rel/overlays/` at the same relative path
inside the release, so this lands at `/app/bin/docker-entrypoint.sh` in the
final image with no separate `COPY` needed):

```sh
#!/bin/sh
set -eu

# The Fly volume mounted at DATABASE_PATH's directory is root:root on first
# boot; the release runs as nobody, so ownership must be fixed here, as
# root, before dropping privilege and exec'ing the real command.
if [ -n "${DATABASE_PATH:-}" ]; then
  mkdir -p "$(dirname "$DATABASE_PATH")"
  chown -R nobody:root "$(dirname "$DATABASE_PATH")"
fi

# Litestream fails closed when its S3 replica is unconfigured (exits before
# -exec ever runs), so only wrap the release in it when a bucket is actually
# set. Otherwise the release runs unreplicated rather than not running at
# all — true on a fresh deploy before secrets are configured, and true of
# every local/dev container run.
if [ -n "${LITESTREAM_BUCKET:-}" ]; then
  exec gosu nobody litestream replicate -config /etc/litestream.yml -exec "$1"
else
  echo "LITESTREAM_BUCKET not set; starting without replication" >&2
  exec gosu nobody "$@"
fi
```

Make it executable (`chmod +x rel/overlays/bin/docker-entrypoint.sh`) — match
the existing `rel/overlays/bin/server`/`migrate` convention. It must be
**root-owned**, not `nobody`-owned: it is the only thing that runs as root at
container start, so if it inherited the release tree's `nobody:root`
ownership, the app process (which runs as `nobody`) could rewrite it and
escalate to root on the next container start. Explicitly `chown root:root`
it in the Dockerfile after the release is copied in — do not rely on
whatever ownership the `COPY --chown=nobody:root` line gives the rest of the
tree.

In the Dockerfile's runner stage, in one combined `RUN` layer (so `curl` does
not remain permanently installed in the final image — installing and purging
it across two separate layers does not shrink the image, only removing it
within the same layer it was added does):

```dockerfile
ARG LITESTREAM_VERSION=<resolve the current release yourself; see below>
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates gosu curl \
  && set -eu; \
     case "$(dpkg --print-architecture)" in \
       amd64) litestream_arch="x86_64" ;; \
       arm64) litestream_arch="arm64" ;; \
       *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
     esac; \
     litestream_asset="litestream-${LITESTREAM_VERSION}-linux-${litestream_arch}.tar.gz"; \
     curl -fsSL -o "/tmp/${litestream_asset}" \
       "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/${litestream_asset}" \
  && curl -fsSL -o /tmp/checksums.txt \
       "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/checksums.txt" \
  && (cd /tmp && grep " ${litestream_asset}\$" checksums.txt | sha256sum -c -) \
  && tar -C /usr/local/bin -xzf "/tmp/${litestream_asset}" litestream \
  && rm "/tmp/${litestream_asset}" /tmp/checksums.txt \
  && apt-get purge -y curl \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*
```

Do not hardcode `LITESTREAM_VERSION` from memory — resolve the current
release yourself (e.g.
`curl -fsSL https://api.github.com/repos/benbjohnson/litestream/releases/latest`
to read the tag and confirm the asset naming, since it has changed across
versions) at the time you write this.

Also:

- `COPY litestream.yml /etc/litestream.yml`.
- Remove the `USER nobody` line (the entrypoint now handles the privilege
  drop after fixing volume ownership as root).
- `RUN chown root:root /app/bin/docker-entrypoint.sh` after the release COPY.
- Set `ENTRYPOINT ["/app/bin/docker-entrypoint.sh"]`.
- `CMD` stays `["/app/bin/server"]` — unchanged from the generator's default.
  The entrypoint script itself decides whether to wrap it in `litestream
  replicate`, not the Dockerfile.

**Verify empirically, not by inspection alone** — Docker is available in this
environment:

1. `docker build -t ganesha-test .` must succeed.
2. Run it against a bind-mounted directory simulating a fresh Fly volume,
   owned by root, and confirm the container does NOT crash with `EACCES` and
   that the mounted directory ends up owned by `nobody` after boot — e.g.:
   ```bash
   mkdir -p /tmp/ganesha-data && sudo chown root:root /tmp/ganesha-data
   docker run --rm \
     -e DATABASE_PATH=/data/ganesha.db \
     -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
     -e PHX_HOST=localhost \
     -v /tmp/ganesha-data:/data \
     ganesha-test whoami
   ```
   (a plain `whoami` as the container command is enough to prove the
   entrypoint's chown-then-drop-privilege sequence runs without error; it does
   not need to boot the full release to prove this specific fix).
3. Confirm `litestream` is on `PATH` in the image:
   `docker run --rm ganesha-test litestream version`.
4. Confirm the entrypoint's fail-open gate actually works: run the image
   with `LITESTREAM_BUCKET` unset (the default — do not set it) and confirm
   the container does NOT immediately exit 1 the way a bare
   `litestream replicate -config /etc/litestream.yml -exec ...` with an
   empty bucket would. A minimal check: run with a command that would only
   succeed past the gate, e.g. `docker run --rm -e DATABASE_PATH=/data/ganesha.db
   -v /tmp/ganesha-data:/data ganesha-test echo booted-without-litestream`
   and confirm it prints and exits 0, not `bucket required for s3 replica`.
5. Confirm the entrypoint script itself is root-owned in the image:
   `docker run --rm --entrypoint sh ganesha-test -c 'stat -c "%U" /app/bin/docker-entrypoint.sh'`
   must print `root`, not `nobody`.

If any of these five fail, the fix is not done — do not report success on
`docker build` succeeding alone, since that would not catch a broken
entrypoint, a wrong binary path, or the crash-loop this exact design was
meant to prevent.

- [ ] **Step 9: Deploy and verify against the running app**

```bash
fly launch --no-deploy --copy-config --name ganesha --region nrt
fly volumes create ganesha_data --region nrt --size 1
fly secrets set SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  TEACHER_EMAIL="<her email>" TEACHER_PASSWORD="<a strong password>" \
  LITESTREAM_ENDPOINT="<S3-compatible endpoint>" \
  LITESTREAM_BUCKET="<bucket name>" \
  LITESTREAM_ACCESS_KEY_ID="<access key>" \
  LITESTREAM_SECRET_ACCESS_KEY="<secret key>"
fly deploy
fly ssh console -C "/app/bin/ganesha eval 'Code.eval_file(\"/app/lib/ganesha-0.1.0/priv/repo/seeds.exs\")'"
```

The four `LITESTREAM_*` secrets are optional for the app to boot (Step 8b's
entrypoint degrades to running unreplicated if `LITESTREAM_BUCKET` is unset),
but required for the actual replication `litestream.yml` exists for — set
them before relying on this as the payment-record backup path. The manual
`Ganesha.Release.migrate()` step is redundant now that Step 5b migrates on
boot; harmless to run, since it's idempotent, but no longer necessary.


Then verify, in this order:
1. `curl -sS https://ganesha.fly.dev/health` returns `ok`.
2. Open the site on a phone, log in, and confirm the bottom navigation is reachable with a thumb.
3. Create a slot, generate a month, enroll a student, record and confirm a payment — the full loop on the real device.
4. `fly logs` shows no errors.

- [ ] **Step 10: Run the full suite and precommit**

Run: `mix precommit`
Expected: compiles without warnings, formatting clean, all tests pass.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: add health check and Fly.io deployment with Litestream replication"
```


---

### Task 17: Enrolling — the use case that ties a sale to a roster

Tasks 1–16 built every part but never wired the act of *selling a month* to the act
of *seating someone*. This is the composition step, kept in its own module so the
LiveView stays thin and the transaction is testable without a browser.

**Files:**
- Create: `lib/ganesha/enrolling.ex`
- Test: `test/ganesha/enrolling_test.exs`

**Interfaces:**
- Consumes: `Catalog.price_for/2`, `Sales.create_purchase/1`, `Roster.enroll/3`, `Roster.add_drop_in/3`, `Roster.mint_package_credits/1`.
- Produces: `Enrolling.enroll_month/1` taking `%{student: Student.t(), slot: Slot.t(), package: Package.t(), sessions: [Session.t()], custom_amount: integer | nil, note: String.t() | nil}` and returning `{:ok, %{purchase: Purchase.t(), attendances: [Attendance.t()], credits: [Credit.t()]}}`; `Enrolling.add_one_off/4` returning `{:ok, %{purchase: Purchase.t(), attendance: Attendance.t()}}`.

- [ ] **Step 1: Write the failing test**

`test/ganesha/enrolling_test.exs`:

```elixir
defmodule Ganesha.EnrollingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}

  defp context do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1
      })

    %{slot: slot, sessions: sessions, student: student, monthly: monthly}
  end

  test "enroll_month/1 creates the purchase, seats every session, and mints the credit" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()

    assert {:ok, result} =
             Enrolling.enroll_month(%{
               student: student,
               slot: slot,
               package: monthly,
               sessions: sessions,
               custom_amount: nil,
               note: nil
             })

    # Five Mondays at 400 each.
    assert result.purchase.list_price == 2000
    assert is_nil(result.purchase.custom_amount)
    assert result.purchase.slot_id == slot.id
    assert length(result.attendances) == 5
    assert Enum.all?(result.attendances, &(&1.kind == "enrolled"))
    assert length(result.credits) == 1
    assert hd(result.credits).expires_on == ~D[2026-08-31]
  end

  test "enroll_month/1 prices only the sessions actually bought" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()
    two = Enum.take(sessions, 2)

    assert {:ok, result} =
             Enrolling.enroll_month(%{
               student: student, slot: slot, package: monthly,
               sessions: two, custom_amount: nil, note: nil
             })

    # 彩華's two classes at the package rate.
    assert result.purchase.list_price == 800
    assert length(result.attendances) == 2
  end

  test "enroll_month/1 honours a custom amount and a note" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()

    assert {:ok, result} =
             Enrolling.enroll_month(%{
               student: student, slot: slot, package: monthly, sessions: sessions,
               custom_amount: 0, note: "按摩器代購"
             })

    assert result.purchase.list_price == 2000
    assert Sales.payable(result.purchase) == 0
    assert result.purchase.note == "按摩器代購"
  end

  test "enroll_month/1 refuses an empty session list" do
    %{slot: slot, student: student, monthly: monthly} = context()

    assert {:error, :no_sessions} =
             Enrolling.enroll_month(%{
               student: student, slot: slot, package: monthly,
               sessions: [], custom_amount: nil, note: nil
             })
  end

  test "enroll_month/1 rolls back completely if a session is already taken" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()

    {:ok, first} =
      Enrolling.enroll_month(%{
        student: student, slot: slot, package: monthly,
        sessions: Enum.take(sessions, 1), custom_amount: nil, note: nil
      })

    purchases_before = length(Sales.list_purchases_for_student(student.id))

    # Overlaps the session already seated by `first`.
    assert {:error, _} =
             Enrolling.enroll_month(%{
               student: student, slot: slot, package: monthly,
               sessions: sessions, custom_amount: nil, note: nil
             })

    assert length(Sales.list_purchases_for_student(student.id)) == purchases_before,
           "a failed enrollment must not leave an orphan purchase behind"

    assert length(Roster.list_for_student(student.id)) == 1
    assert first.purchase.id == hd(Sales.list_purchases_for_student(student.id)).id
  end

  test "add_one_off/4 creates a drop-in purchase and seats one session" do
    %{sessions: sessions} = context()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    assert {:ok, result} = Enrolling.add_one_off(hd(sessions), jennifer, drop_in, [])

    assert result.purchase.list_price == 450
    assert is_nil(result.purchase.slot_id), "a drop-in is not tied to a slot"
    assert result.attendance.kind == "drop_in"
  end

  test "add_one_off/4 supports a trial and a custom amount" do
    %{sessions: sessions} = context()
    {:ok, yufang} = People.create_student(%{display_name: "育芳"})

    {:ok, trial} =
      Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 450})

    assert {:ok, result} =
             Enrolling.add_one_off(hd(sessions), yufang, trial,
               custom_amount: 400,
               note: "朋友介紹"
             )

    assert Sales.payable(result.purchase) == 400
    assert result.attendance.kind == "trial"
  end

  test "add_one_off/4 mints no credit" do
    %{sessions: sessions} = context()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, _} = Enrolling.add_one_off(hd(sessions), jennifer, drop_in, [])

    assert Roster.available_credits(jennifer.id, ~D[2026-08-03]) == []
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha/enrolling_test.exs`
Expected: FAIL — `Ganesha.Enrolling` is undefined.

- [ ] **Step 3: Implement the module**

`lib/ganesha/enrolling.ex`:

```elixir
defmodule Ganesha.Enrolling do
  @moduledoc """
  The use case that joins a sale to a roster.

  Selling a month means three things happening together: a purchase, one
  attendance row per bought session, and the package's included makeup credits.
  They run in a single transaction because a purchase without attendance rows
  has no period (and so no credit expiry), and attendance rows without a
  purchase would be free classes.
  """

  alias Ganesha.{Catalog, Repo, Roster, Sales}

  @doc """
  Enrolls a student in a slot for a set of that month's sessions.

  `list_price` is a snapshot of `price_per_class × length(sessions)`;
  `custom_amount` overrides what is actually owed without disturbing it.
  """
  def enroll_month(%{sessions: []}), do: {:error, :no_sessions}

  def enroll_month(%{
        student: student,
        slot: slot,
        package: package,
        sessions: sessions,
        custom_amount: custom_amount,
        note: note
      }) do
    Repo.transaction(fn ->
      {:ok, purchase} =
        Sales.create_purchase(%{
          student_id: student.id,
          package_id: package.id,
          slot_id: slot.id,
          list_price: Catalog.price_for(package, length(sessions)),
          custom_amount: custom_amount,
          note: note
        })

      attendances =
        Enum.map(sessions, fn session ->
          case Roster.enroll(session, student, purchase) do
            {:ok, attendance} -> attendance
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      # Minting happens after the attendance rows exist, because expiry is the
      # end of the month of the earliest one.
      {:ok, credits} = Roster.mint_package_credits(purchase)

      %{purchase: purchase, attendances: attendances, credits: credits}
    end)
  end

  @doc """
  Seats a single non-enrolled attendee: a drop-in or a trial.

  No `slot_id`: a one-off is not a monthly commitment to a weekday.
  Options: `:custom_amount`, `:note`.
  """
  def add_one_off(session, student, package, opts) do
    Repo.transaction(fn ->
      {:ok, purchase} =
        Sales.create_purchase(%{
          student_id: student.id,
          package_id: package.id,
          slot_id: nil,
          list_price: Catalog.price_for(package, 1),
          custom_amount: Keyword.get(opts, :custom_amount),
          note: Keyword.get(opts, :note)
        })

      case Roster.add_drop_in(session, student, purchase) do
        {:ok, attendance} -> %{purchase: purchase, attendance: attendance}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/enrolling_test.exs`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add enrolling use case joining purchases to rosters"
```

---

### Task 18: UI — the enroll screen

**Files:**
- Create: `lib/ganesha_web/live/enroll_live.ex`
- Modify: `lib/ganesha_web/live/month_live.ex` (link each slot to its enroll screen)
- Modify: `lib/ganesha_web/router.ex`
- Test: `test/ganesha_web/live/enroll_live_test.exs`

**Interfaces:**
- Consumes: `Enrolling.enroll_month/1`, `Studio.get_slot!/1`, `Studio.sessions_for_slot_in_month/2`, `People.list_active_students/0`, `Catalog.list_active_packages/0`, `Catalog.price_for/2`, `Sales.list_purchases_for_student/1`, `Sales.payable/1`, `Sales.record_payment/1`, `Roster.list_for_session/1`, `Reporting.purchase_period/1`.
- Produces: route `~p"/enroll/:slot_id/:year/:month"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha_web/live/enroll_live_test.exs`:

```elixir
defmodule GaneshaWeb.EnrollLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp august_monday do
    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1
      })

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    %{slot: slot, sessions: sessions, student: student, monthly: monthly}
  end

  test "lists the month's sessions and the students available to enroll", %{conn: conn} do
    %{slot: slot, student: student} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    assert has_element?(view, "#enroll-form")
    assert has_element?(view, "#session-check-#{Enum.at(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01]), 0).id}")
    assert render(view) =~ student.display_name
  end

  test "falls back instead of crashing on malformed year or month", %{conn: conn} do
    __omp_magic("", "{slot: slot} = august_monday()")

    assert {:ok, _view, html} = live(conn, ~p"/enroll/#{slot.id}/oops/13")
    assert html =~ slot.label
  end

  test "enrolls a student in every session of the month", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id))
    })
    |> render_submit()

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.list_price == 2000
    assert length(Roster.list_for_student(student.id)) == 5
    assert length(Roster.available_credits(student.id, ~D[2026-08-31])) == 1

    assert has_element?(view, "#purchase-#{purchase.id}")
  end

  test "enrolls in a subset of dates and prices only those", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => sessions |> Enum.take(2) |> Enum.map(&to_string(&1.id))
    })
    |> render_submit()

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.list_price == 800
  end

  test "applies a custom amount with a note", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id)),
      "custom_amount" => "1600",
      "note" => "友情價"
    })
    |> render_submit()

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.list_price == 2000
    assert Sales.payable(purchase) == 1600
    assert purchase.note == "友情價"
  end

  test "shows an error when no dates are selected", %{conn: conn} do
    %{slot: slot, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    html =
      view
      |> form("#enroll-form", %{"student_id" => student.id, "package_id" => monthly.id})
      |> render_submit()

    assert html =~ "請選擇上課日期"
    assert Sales.list_purchases_for_student(student.id) == []
  end

  test "records a payment against an enrollment", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id))
    })
    |> render_submit()

    [purchase] = Sales.list_purchases_for_student(student.id)

    view
    |> form("#payment-form-#{purchase.id}", %{
      "amount" => "2000",
      "method" => "line_pay",
      "reported_last5" => "12345"
    })
    |> render_submit()

    assert [payment] = Sales.list_payments_for_purchase(purchase.id)
    assert payment.amount == 2000
    assert payment.method == "line_pay"
    assert payment.reported_last5 == "12345"
    assert payment.state == "claimed", "recording is not confirming"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/live/enroll_live_test.exs`
Expected: FAIL — no route matches `/enroll/...`.

- [ ] **Step 3: Implement EnrollLive**

`lib/ganesha_web/live/enroll_live.ex`:

```elixir
defmodule GaneshaWeb.EnrollLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Clock, Enrolling, People, Reporting, Roster, Sales, Studio}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"slot_id" => slot_id} = params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:slot, Studio.get_slot!(slot_id))
     |> assign_month(params)
     |> load()}
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

  defp load(socket) do
    sessions = Studio.sessions_for_slot_in_month(socket.assigns.slot, socket.assigns.month)
    scheduled = Enum.filter(sessions, &(&1.state == "scheduled"))

    socket
    |> assign(:sessions, sessions)
    |> assign(:scheduled, scheduled)
    |> assign(:students, People.list_active_students())
    |> assign(:packages, Catalog.list_active_packages())
    |> assign(:enrollments, enrollments_for(scheduled))
  end

  # Purchases reachable from this slot-month, derived through the attendance
  # rows on its sessions. There is no month column to query directly.
  defp enrollments_for(sessions) do
    sessions
    |> Enum.flat_map(&Roster.list_for_session/1)
    |> Enum.filter(&(&1.kind == "enrolled" and &1.purchase_id))
    |> Enum.uniq_by(& &1.purchase_id)
    |> Enum.map(fn attendance ->
      purchase = Sales.get_purchase!(attendance.purchase_id)

      %{
        purchase: purchase,
        student: purchase.student,
        payable: Sales.payable(purchase),
        paid: purchase.id |> Sales.list_payments_for_purchase() |> Enum.map(& &1.amount) |> Enum.sum(),
        period: Reporting.purchase_period(purchase.id)
      }
    end)
    |> Enum.sort_by(& &1.student.display_name)
  end

  @impl true
  def handle_event("enroll", params, socket) do
    session_ids = Map.get(params, "session_ids", [])

    chosen =
      Enum.filter(socket.assigns.scheduled, &(to_string(&1.id) in session_ids))

    cond do
      chosen == [] ->
        {:noreply, put_flash(socket, :error, "請選擇上課日期")}

      true ->
        student = Enum.find(socket.assigns.students, &(to_string(&1.id) == params["student_id"]))
        package = Enum.find(socket.assigns.packages, &(to_string(&1.id) == params["package_id"]))

        case Enrolling.enroll_month(%{
               student: student,
               slot: socket.assigns.slot,
               package: package,
               sessions: chosen,
               custom_amount: blank_to_nil(params["custom_amount"]),
               note: blank_to_nil(params["note"])
             }) do
          {:ok, _result} ->
            {:noreply, socket |> put_flash(:info, "已加入 #{student.display_name}") |> load()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "無法加入，可能已在名單中")}
        end
    end
  end

  def handle_event("record_payment", %{"purchase-id" => id} = params, socket) do
    case Sales.record_payment(%{
           purchase_id: id,
           amount: params["amount"],
           method: params["method"],
           paid_on: Clock.today(),
           reported_last5: blank_to_nil(params["reported_last5"]),
           source: "manual"
         }) do
      {:ok, _payment} ->
        {:noreply,
         socket
         |> put_flash(:info, "已記錄，待確認入帳")
         |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "金額或方式不正確")}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@slot.label}</h1>
        <p class="text-sm text-zinc-500">{@month.year} 年 {@month.month} 月報名</p>

        <form id="enroll-form" phx-submit="enroll" class="mt-4 space-y-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800">
          <label class="block text-sm">
            學生
            <select name="student_id" class="mt-1 min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900">
              <option :for={student <- @students} value={student.id}>{student.display_name}</option>
            </select>
          </label>

          <label class="block text-sm">
            方案
            <select name="package_id" class="mt-1 min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900">
              <option :for={package <- @packages} value={package.id}>
                {package.name}（{package.price_per_class}／堂）
              </option>
            </select>
          </label>

          <fieldset>
            <legend class="text-sm">上課日期</legend>
            <div class="mt-1 flex flex-wrap gap-2">
              <label
                :for={session <- @scheduled}
                class="flex min-h-[44px] items-center gap-2 rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700"
              >
                <input
                  type="checkbox"
                  id={"session-check-#{session.id}"}
                  name="session_ids[]"
                  value={session.id}
                  checked
                  class="size-5"
                />
                {session.date.month}/{session.date.day}
              </label>
            </div>
          </fieldset>

          <div class="flex flex-wrap gap-2">
            <input
              type="number"
              name="custom_amount"
              placeholder="自訂金額（可留空）"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="text"
              name="note"
              placeholder="備註"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
          </div>

          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">
            加入名單
          </button>
        </form>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">本月名單</h2>
        <section
          :for={row <- @enrollments}
          id={"purchase-#{row.purchase.id}"}
          class="mt-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <header class="flex items-baseline justify-between gap-2">
            <.link navigate={~p"/students/#{row.student.id}"} class="font-medium">
              {row.student.display_name}
            </.link>
            <span class="font-mono text-sm">
              NT$ {row.paid} / {row.payable}
            </span>
          </header>

          <p :if={row.period} class="mt-1 text-xs text-zinc-500">
            {row.period.first} – {row.period.last}
          </p>

          <form
            id={"payment-form-#{row.purchase.id}"}
            phx-submit="record_payment"
            class="mt-3 flex flex-wrap gap-2"
          >
            <input type="hidden" name="purchase-id" value={row.purchase.id} />
            <input
              type="number"
              name="amount"
              placeholder="金額"
              value={row.payable - row.paid}
              class="min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <select
              name="method"
              class="min-h-[44px] rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            >
              <option value="line_pay">Line Pay</option>
              <option value="line_bank">LINE Bank</option>
              <option value="cash">現金</option>
              <option value="other">其他</option>
            </select>
            <input
              type="text"
              name="reported_last5"
              placeholder="帳後五碼"
              inputmode="numeric"
              class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              記錄
            </button>
          </form>
        </section>

        <p :if={@enrollments == []} id="no-enrollments" class="mt-3 text-sm text-zinc-400">
          還沒有人報名
        </p>
      </div>

      <Layouts.bottom_nav active={:month} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Link the month screen to the enroll screen**

In `lib/ganesha_web/live/month_live.ex`, inside the slot `<header>`, after the generate button, add:

```elixir
            <.link
              :if={sessions != []}
              id={"enroll-slot-#{slot.id}"}
              navigate={~p"/enroll/#{slot.id}/#{@month.year}/#{@month.month}"}
              class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm leading-[44px] dark:border-zinc-700"
            >
              報名
            </.link>
```

- [ ] **Step 5: Add the route**

```elixir
      live "/enroll/:slot_id/:year/:month", EnrollLive, :index
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/enroll_live_test.exs test/ganesha_web/live/month_live_test.exs`
Expected: PASS, 10 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add enroll screen for monthly signups and payment recording"
```

---

### Task 19: UI — drop-ins, trials, and booking a makeup

**Files:**
- Create: `lib/ganesha_web/live/session_live.ex`
- Modify: `lib/ganesha_web/live/enroll_live.ex` (link each date to its session screen)
- Modify: `lib/ganesha_web/router.ex`
- Test: `test/ganesha_web/live/session_live_test.exs`

**Interfaces:**
- Consumes: `Studio.get_session!/1`, `Roster.list_for_session/1`, `Roster.book_makeup/3`, `Roster.available_credits/2`, `Enrolling.add_one_off/4`, `People.list_active_students/0`, `People.get_student!/1`, `Catalog.list_active_packages/0`.
- Produces: route `~p"/sessions/:id"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha_web/live/session_live_test.exs`:

```elixir
defmodule GaneshaWeb.SessionLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp august do
    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1
      })

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, monday} =
      Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, friday} =
      Studio.create_slot(%{
        weekday: 5, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週五 基礎瑜伽"
      })

    {:ok, mondays} = Studio.generate_month(monday, ~D[2026-08-01])
    {:ok, fridays} = Studio.generate_month(friday, ~D[2026-08-01])

    %{monthly: monthly, drop_in: drop_in, monday: monday, mondays: mondays, fridays: fridays}
  end

  test "shows the roster for a session", %{conn: conn} do
    %{mondays: mondays, monday: monday, monthly: monthly} = august()
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: student, slot: monday, package: monthly,
        sessions: mondays, custom_amount: nil, note: nil
      })

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert render(view) =~ "Lulu"
    assert has_element?(view, "#one-off-form")
  end

  test "adds a drop-in to the session", %{conn: conn} do
    %{mondays: mondays, drop_in: drop_in} = august()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view
    |> form("#one-off-form", %{"student_id" => jennifer.id, "package_id" => drop_in.id})
    |> render_submit()

    assert [attendance] = Roster.list_for_student(jennifer.id)
    assert attendance.kind == "drop_in"
    assert [purchase] = Sales.list_purchases_for_student(jennifer.id)
    assert Sales.payable(purchase) == 450
  end

  test "books a makeup using an available credit on another weekday", %{conn: conn} do
    %{mondays: mondays, fridays: fridays, monday: monday, monthly: monthly} = august()
    {:ok, lanzi} = People.create_student(%{display_name: "蘭子"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: lanzi, slot: monday, package: monthly,
        sessions: mondays, custom_amount: nil, note: nil
      })

    friday = hd(fridays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{friday.id}")

    assert has_element?(view, "#makeup-form")

    view
    |> form("#makeup-form", %{"student_id" => lanzi.id})
    |> render_submit()

    makeup = Enum.find(Roster.list_for_student(lanzi.id), &(&1.kind == "makeup"))
    refute is_nil(makeup)
    assert is_nil(makeup.purchase_id), "a makeup is paid for by a credit, not a sale"
    assert Roster.available_credits(lanzi.id, friday.date) == []
  end

  test "offers no makeup form when nobody holds a usable credit", %{conn: conn} do
    %{fridays: fridays} = august()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{hd(fridays).id}")
    refute has_element?(view, "#makeup-form")
  end

  test "reports the reason when a makeup cannot be booked", %{conn: conn} do
    %{mondays: mondays, monday: monday, monthly: monthly} = august()
    {:ok, lanzi} = People.create_student(%{display_name: "蘭子"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: lanzi, slot: monday, package: monthly,
        sessions: mondays, custom_amount: nil, note: nil
      })

    # The credit expires at the end of August, so a September session refuses it.
    {:ok, tuesday} =
      Studio.create_slot(%{
        weekday: 2, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "週二"
      })

    {:ok, september} = Studio.generate_month(tuesday, ~D[2026-09-01])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{hd(september).id}")

    refute has_element?(view, "#makeup-form"),
           "an expired credit must not be offered for a later month"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/live/session_live_test.exs`
Expected: FAIL — no route matches `/sessions/:id`.

- [ ] **Step 3: Implement SessionLive**

`lib/ganesha_web/live/session_live.ex`:

```elixir
defmodule GaneshaWeb.SessionLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Enrolling, People, Roster, Studio}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, socket |> assign(:session, Studio.get_session!(id)) |> load()}
  end

  defp load(socket) do
    session = socket.assigns.session
    students = People.list_active_students()

    # Only offer a makeup to someone who actually holds a credit usable on this
    # date: same student, unspent, and not expired. Offering an unusable credit
    # would surface an error she cannot act on.
    eligible =
      Enum.filter(students, fn student ->
        Roster.available_credits(student.id, session.date) != []
      end)

    socket
    |> assign(:attendances, Roster.list_for_session(session))
    |> assign(:students, students)
    |> assign(:makeup_candidates, eligible)
    |> assign(:one_off_packages, Enum.reject(Catalog.list_active_packages(), &(&1.kind == "monthly")))
  end

  @impl true
  def handle_event("add_one_off", params, socket) do
    student = People.get_student!(params["student_id"])

    package =
      Enum.find(socket.assigns.one_off_packages, &(to_string(&1.id) == params["package_id"]))

    opts = [custom_amount: blank_to_nil(params["custom_amount"]), note: blank_to_nil(params["note"])]

    case Enrolling.add_one_off(socket.assigns.session, student, package, opts) do
      {:ok, _result} ->
        {:noreply, socket |> put_flash(:info, "已加入 #{student.display_name}") |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "無法加入，可能已在名單中")}
    end
  end

  def handle_event("book_makeup", %{"student_id" => student_id}, socket) do
    session = socket.assigns.session
    student = People.get_student!(student_id)

    case Roster.available_credits(student.id, session.date) do
      [credit | _] ->
        case Roster.book_makeup(session, student, credit) do
          {:ok, _attendance} ->
            {:noreply, socket |> put_flash(:info, "已安排補課") |> load()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, makeup_error(reason))}
        end

      [] ->
        {:noreply, put_flash(socket, :error, "沒有可用的補課額度")}
    end
  end

  defp makeup_error(:credit_not_owned), do: "這張額度不屬於這位學生"
  defp makeup_error(:credit_already_consumed), do: "這張額度已使用"
  defp makeup_error(:credit_expired), do: "這張額度已過期"
  defp makeup_error(_other), do: "無法安排補課"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp attendee_label(attendance) do
    case attendance.kind do
      "makeup" -> "補課"
      "drop_in" -> "單堂"
      "trial" -> "體驗"
      _ -> "月課程"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@session.slot.label}</h1>
        <p class="text-sm text-zinc-500">{@session.date} · {@session.style}</p>

        <ul class="mt-4 space-y-2">
          <li
            :for={attendance <- @attendances}
            id={"attendance-#{attendance.id}"}
            class="flex items-center justify-between rounded-xl border border-zinc-200 p-3 dark:border-zinc-800"
          >
            <span>{attendance.student.display_name}</span>
            <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
              {attendee_label(attendance)}
            </span>
          </li>
          <li :if={@attendances == []} class="text-sm text-zinc-400">名單是空的</li>
        </ul>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">加入單堂／體驗</h2>
        <form
          id="one-off-form"
          phx-submit="add_one_off"
          class="mt-2 space-y-2 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <select name="student_id" class="min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900">
            <option :for={student <- @students} value={student.id}>{student.display_name}</option>
          </select>
          <select name="package_id" class="min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900">
            <option :for={package <- @one_off_packages} value={package.id}>
              {package.name}（{package.price_per_class}）
            </option>
          </select>
          <div class="flex gap-2">
            <input
              type="number"
              name="custom_amount"
              placeholder="自訂金額"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="text"
              name="note"
              placeholder="備註"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
          </div>
          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">加入</button>
        </form>

        <div :if={@makeup_candidates != []}>
          <h2 class="mt-6 text-sm font-medium text-zinc-500">安排補課</h2>
          <form
            id="makeup-form"
            phx-submit="book_makeup"
            class="mt-2 flex gap-2 rounded-2xl border border-purple-200 p-4 dark:border-purple-900"
          >
            <select name="student_id" class="min-h-[44px] flex-1 rounded-lg border-zinc-300 dark:bg-zinc-900">
              <option :for={student <- @makeup_candidates} value={student.id}>
                {student.display_name}
              </option>
            </select>
            <button class="min-h-[44px] rounded-lg bg-purple-600 px-4 text-sm text-white">補課</button>
          </form>
        </div>
      </div>

      <Layouts.bottom_nav active={:month} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Link each date on the enroll screen to its session**

In `lib/ganesha_web/live/enroll_live.ex`, wrap the date label inside the checkbox list with a link, added after the `</fieldset>`:

```elixir
          <div class="flex flex-wrap gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
            <.link
              :for={session <- @scheduled}
              id={"open-session-#{session.id}"}
              navigate={~p"/sessions/#{session.id}"}
              class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm leading-[44px] dark:border-zinc-700"
            >
              {session.date.month}/{session.date.day} 名單
            </.link>
          </div>
```

- [ ] **Step 5: Add the route**

```elixir
      live "/sessions/:id", SessionLive, :show
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/session_live_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add session screen for drop-ins, trials, and makeup booking"
```

---

### Task 20: UI — packages and studio settings, plus a dead-code sweep

**Files:**
- Create: `lib/ganesha_web/live/settings_live.ex`
- Modify: `lib/ganesha_web/router.ex`, `lib/ganesha_web/components/layouts.ex`
- Test: `test/ganesha_web/live/settings_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.list_packages/0`, `Catalog.update_package/2`, `Catalog.create_package/1`, `Publishing.get_settings/0`, `Publishing.update_settings/1`.
- Produces: route `~p"/settings"`, reachable from the Publish screen.

- [ ] **Step 1: Write the failing test**

`test/ganesha_web/live/settings_live_test.exs`:

```elixir
defmodule GaneshaWeb.SettingsLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Publishing}

  setup :register_and_log_in_user

  test "lists packages and lets the price change", %{conn: conn} do
    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#package-#{pkg.id}")

    view
    |> form("#package-form-#{pkg.id}", %{"price_per_class" => "450", "included_makeups" => "1"})
    |> render_submit()

    updated = Catalog.get_package!(pkg.id)
    assert updated.price_per_class == 450
    assert updated.included_makeups == 1
  end

  test "saves the bank details used by the announcement footer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#studio-settings-form", %{
      "settings" => %{
        "bank_name" => "連線商業銀行",
        "bank_code" => "824",
        "account_number" => "111001756051",
        "transfer_deadline" => "8/15",
        "closing_note" => "＊＊或者 line pay Money"
      }
    })
    |> render_submit()

    settings = Publishing.get_settings()
    assert settings.bank_code == "824"
    assert settings.transfer_deadline == "8/15"
  end

  test "a changed package price flows into the announcement", %{conn: conn} do
    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, slot} =
      Ganesha.Studio.create_slot(%{
        weekday: 1, start_time: ~T[09:30:00], end_time: ~T[10:45:00],
        default_style: "基礎", label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Ganesha.Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, _} = Catalog.update_package(pkg, %{price_per_class: 500})

    {:ok, view, _html} = live(conn, ~p"/publish/2026/8")
    assert render(view) =~ "2500元 /5 堂"
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/ganesha_web/live/settings_live_test.exs`
Expected: FAIL — no route matches `/settings`.

- [ ] **Step 3: Implement SettingsLive**

`lib/ganesha_web/live/settings_live.ex`:

```elixir
defmodule GaneshaWeb.SettingsLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Publishing}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  defp load(socket) do
    settings = Publishing.get_settings()

    socket
    |> assign(:packages, Catalog.list_packages())
    |> assign(:settings_form, to_form(Publishing.change_settings(settings), as: :settings))
  end

  @impl true
  def handle_event("save_package", %{"package-id" => id} = params, socket) do
    package = Catalog.get_package!(id)

    attrs = %{
      price_per_class: params["price_per_class"],
      included_makeups: params["included_makeups"]
    }

    case Catalog.update_package(package, attrs) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "已更新方案") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "金額不正確")}
    end
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Publishing.update_settings(params) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "已儲存") |> load()}
      {:error, changeset} -> {:noreply, assign(socket, :settings_form, to_form(changeset, as: :settings))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">方案與設定</h1>

        <section
          :for={package <- @packages}
          id={"package-#{package.id}"}
          class="mt-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <h2 class="font-medium">{package.name}<span class="ml-2 text-xs text-zinc-500">{package.kind}</span></h2>

          <form
            id={"package-form-#{package.id}"}
            phx-submit="save_package"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <input type="hidden" name="package-id" value={package.id} />
            <label class="text-xs text-zinc-500">
              每堂
              <input
                type="number"
                name="price_per_class"
                value={package.price_per_class}
                class="ml-1 min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
              />
            </label>
            <label class="text-xs text-zinc-500">
              補課數
              <input
                type="number"
                name="included_makeups"
                value={package.included_makeups}
                class="ml-1 min-h-[44px] w-20 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
              />
            </label>
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              儲存
            </button>
          </form>
        </section>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">匯款資訊（公告用）</h2>
        <.form
          for={@settings_form}
          id="studio-settings-form"
          phx-submit="save_settings"
          class="mt-2 space-y-2 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <.input field={@settings_form[:bank_name]} type="text" label="銀行名稱" />
          <.input field={@settings_form[:bank_code]} type="text" label="銀行代號" />
          <.input field={@settings_form[:account_number]} type="text" label="帳號" />
          <.input field={@settings_form[:transfer_deadline]} type="text" label="轉帳期限" />
          <.input field={@settings_form[:closing_note]} type="text" label="結尾備註" />
          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">儲存</button>
        </.form>
      </div>

      <Layouts.bottom_nav active={:publish} />
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Add the route and a link from the Publish screen**

```elixir
      live "/settings", SettingsLive, :index
```

In `lib/ganesha_web/live/publish_live.ex`, beside the 複製 button:

```elixir
          <.link
            id="open-settings"
            navigate={~p"/settings"}
            class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm leading-[44px] dark:border-zinc-700"
          >
            設定
          </.link>
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/ganesha_web/live/settings_live_test.exs`
Expected: PASS, 3 tests.

- [ ] **Step 6: Sweep dead code**

Every public function must have a caller or a documented phase-2 purpose. Check each:

```bash
for fn in list_sessions_for_month change_payment comped dispute_payment \
          find_by_alias find_by_line_user_id add_alias list_active_students \
          change_slot change_package expired_credits purchase_period; do
  printf '%-24s %s\n' "$fn" "$(grep -rn "$fn" lib | grep -v "def $fn" | wc -l | tr -d ' ')"
done
```

Resolve each result:
- `find_by_alias/1`, `find_by_line_user_id/1`, `add_alias/2` — **keep with zero callers.** They are the phase-2 parser's identity path, are covered by tests, and the alias table exists for them. Leave a `@doc` noting they are consumed by LINE ingestion.
- `change_slot/2`, `change_payment/2`, `list_sessions_for_month/1` — **delete** if the sweep shows no caller. They were written speculatively; the month screen loads per slot, and payment forms are hand-built.
- `comped/1` — surface it in the settings screen as a monthly "已折抵" total, or delete it. Do not leave it unused.

- [ ] **Step 7: Full verification**

Run: `mix precommit`
Expected: compiles with no warnings, formatting clean, all tests pass.

Then exercise the whole loop by hand against `mix phx.server`, on a phone-sized viewport:
1. `/settings` — set the monthly price and the bank details.
2. `/month` — generate August for one slot.
3. `/enroll/...` — enroll a student in all dates; confirm the price is dates × price.
4. Record a payment, then confirm it on `/students/:id`; the balance must reach zero.
5. `/sessions/:id` — add a drop-in, then cancel a session on `/month` and book the resulting makeup on another weekday.
6. `/money` — the revenue figure and the 起徵點 gauge must both move.
7. `/publish` — the announcement must contain the dates, the price, and the bank footer; 複製 must work.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add packages and studio settings screen, remove unused functions"
```

---

## Self-review notes

Checked against the spec after writing. Three findings, all fixed above rather than left
for the implementer:

1. **The app was unusable as first drafted.** Tasks 1–16 built every context and screen but
   never wired *selling a month* to *seating someone*: `Roster.add_drop_in/3`,
   `Roster.book_makeup/3`, `Roster.mint_package_credits/1` and `Catalog.price_for/2` had no
   caller outside test fixtures. Tasks 17–19 add the `Enrolling` use case and the enroll and
   session screens that drive it.
2. **Spec §4.1 screen 7 was missing.** "Packages & settings" had no task; the price list and
   bank details were reachable only through seeds. Task 20 adds it.
3. **Speculative functions.** Several public functions had no consumer. Task 20 step 6 makes
   the sweep explicit and states which to keep (the phase-2 parser's identity path) and which
   to delete.

Type consistency was checked across tasks: `Sales.payable/1`, `Catalog.price_for/2`,
`Roster.available_credits/2`, `Roster.book_makeup/3`, `Enrolling.enroll_month/1` and
`Enrolling.add_one_off/4` are called with the same names and arities everywhere they appear.
`Publishing.change_settings/2` is defined with a single clause taking a struct, and is called
that way in Task 20.

---

## After the plan

Phase 1 is complete when she has run **one real month** through it with manual entry:
packages seeded, slots generated, students enrolled, payments confirmed, and the
announcement posted from the Publish screen.

Only then does phase 2 (LINE ingestion) get its own plan. The parser's value depends
entirely on the ledger being correct first, and a parser writing into a wrong model is
worse than no parser at all.

Before phase 2 work begins, one fact must be checked in her LINE group: **only one
Official Account may be in a group at a time.** If another bot is already there, the
passive-listener design cannot receive messages and needs rethinking. This does not
affect phase 1.
