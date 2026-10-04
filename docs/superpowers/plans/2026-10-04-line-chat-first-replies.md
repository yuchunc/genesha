# LINE Chat-First Replies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace web-shaped LINE replies with chat-first ones: one code-written sentence per Draft, minimal Confirm/Discard cards, readable failure reasons, and text-only answers to questions.

**Architecture:** Every `:change` task gains `summary/2 :: String.t()` (built from `parsed` only) and loses `describe/2`. `Assistant.draft_summary/2` is the single entry point used by the Draft card, outcomes, history lines, group push, `pending_drafts` and the dashboard. Lookups drop their card payloads; `show_card`, `Turn.cards` and the lookup renderers in `Line.Cards` are deleted, and the teacher prompt gains reply rules.

**Tech Stack:** Elixir 1.20, Phoenix 1.8 LiveView, Ecto + SQLite, Oban, LINE Messaging API (Flex), `Provider.Mock` / `Line.Client.Mock` for tests.

**Spec:** `docs/superpowers/specs/2026-10-04-line-chat-first-replies-design.md` (supersedes §6.2 and the lookup-card parts of §3.1 of `2026-10-02-line-teacher-assistant-design.md`).

## Global Constraints

- Summaries read `parsed` only; never query the database.
- Summaries: no `%{`, no markdown; `en` mirrors `zh-TW`; any other locale gets `zh-TW`.
- zh-TW parentheses are full-width `（…）`, list separator `、`, clause separator `，`; English uses ` (…)`, `, `.
- Money always via `Ganesha.Assistant.Format.money/1` (`NT$3,200`).
- No "Open on web" anywhere in chat. Postback data unchanged: `action=confirm&draft_id=N`, `action=discard&draft_id=N`.
- Turn reply order: model text → Draft carousel (≤ 12 bubbles) → quick-reply chips. Max 3 messages.
- Tests assert facts (names, amounts, dates, ids, postbacks), never exact sentences.
- AGENTS.md: `mix precommit` at the end; LiveView tests use `has_element?/2`.
- Never `alias Ganesha.Assistant.Task`.

## File Structure

| File | Change |
|---|---|
| `lib/ganesha/assistant/summary.ex` | **New.** Shared sentence pieces (day, time, money, method, words, paren). |
| `lib/ganesha/assistant/task.ex` | `summary/2` replaces `describe/2`; `answer/2` loses `:card`. |
| `lib/ganesha/assistant/tasks/*.ex` (15 change tasks) | Add `summary/2`, delete `describe/2` + its helpers. |
| `lib/ganesha/assistant.ex` | `draft_summary/2` replaces `describe_draft/2`. |
| `lib/ganesha/line/cards.ex` | Only `draft_bubble/2`, `draft_carousel/2`, `history_line/2` (drafts). |
| `lib/ganesha/line/reply.ex` | No lookup cards. |
| `lib/ganesha/line/labels.ex` | Readable failure reasons; drop card-only labels. |
| `lib/ganesha/assistant/conversation.ex` | Outcomes use summary + readable reason. |
| `lib/ganesha/assistant/agent.ex`, `turn.ex`, `tasks.ex` | Drop `show_card`, `Turn.cards`. |
| 6 lookup tasks + `lookup.ex` | Drop payloads/cards. |
| `lib/ganesha/assistant/prompts.ex` | New reply rules. |
| `lib/ganesha/assistant/group_draft_notifier.ex`, `tasks/pending_drafts.ex`, `lib/ganesha_web/live/dashboard_live.ex` | Use `draft_summary`. |
| `lib/mix/tasks/line.validate_cards.ex` | Draft bubble + choices only. |
| `priv/scripts/line_smoke.exs`, `line_real_questions.exs` | Checks updated. |

---

### Task 1: `Summary` helpers and the `summary/2` callback

**Files:**
- Create: `lib/ganesha/assistant/summary.ex`, `test/ganesha/assistant/summary_test.exs`
- Modify: `lib/ganesha/assistant/task.ex`

**Interfaces:**
- Produces: `Ganesha.Assistant.Summary` with `day/2`, `time_range/2`, `money/1`, `method/2`, `words/1`, `paren/2`, `month_name/2`, `weekday/2`, `kind/2`. Optional callback `summary/2` on `Ganesha.Assistant.Task` (made the only Draft-description callback in Task 5).

- [ ] **Step 1: Write the failing test** — `test/ganesha/assistant/summary_test.exs`:

```elixir
defmodule Ganesha.Assistant.SummaryTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Summary

  test "day/2 reads an ISO date in each locale and tolerates junk" do
    assert Summary.day("2026-10-08", "zh-TW") == "10/8 週四"
    assert Summary.day("2026-10-08", "en") == "Thu 10/8"
    assert Summary.day(nil, "zh-TW") == ""
    assert Summary.day("nope", "en") == ""
  end

  test "time_range/2 reads ISO times or passes a display range through" do
    assert Summary.time_range("19:00:00", "20:15:00") == "19:00–20:15"
    assert Summary.time_range("19:00–20:15", nil) == "19:00–20:15"
    assert Summary.time_range(nil, nil) == ""
  end

  test "words/1 drops blanks; paren/2 wraps per locale" do
    assert Summary.words(["a", nil, "", "b"]) == "a b"
    assert Summary.paren(["LINE Pay", "10/3"], "zh-TW") == "（LINE Pay，10/3）"
    assert Summary.paren(["LINE Pay", nil], "en") == " (LINE Pay)"
    assert Summary.paren([nil, ""], "en") == ""
  end

  test "month_name/2, weekday/2, method/2 and kind/2 speak both languages" do
    assert Summary.month_name("2026-10", "zh-TW") == "10月"
    assert Summary.month_name("2026-10-01", "en") == "October"
    assert Summary.weekday(3, "zh-TW") == "週三"
    assert Summary.weekday(3, "en") == "Wed"
    assert Summary.method("cash", "zh-TW") == "現金"
    assert Summary.method("cash", "en") == "cash"
    assert Summary.kind("drop_in", "zh-TW") == "單堂"
    assert Summary.kind("trial", "en") == "trial"
  end
end
```

- [ ] **Step 2: Run** — `mix test test/ganesha/assistant/summary_test.exs` — FAIL (module not defined).

- [ ] **Step 3: Implement** `lib/ganesha/assistant/summary.ex`:

```elixir
defmodule Ganesha.Assistant.Summary do
  @moduledoc """
  Shared pieces of the one-sentence Draft summaries (chat-first replies spec §1).
  Every function takes the plain values a task stored in `parsed`, so a
  summary never touches the database. Blank or unreadable input yields `""`.
  """

  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @en_weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  @spec day(String.t() | nil, String.t()) :: String.t()
  def day(iso, locale) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Format.session_day(date, locale)
      {:error, _} -> ""
    end
  end

  def day(_iso, _locale), do: ""

  @doc "`19:00–20:15` from two ISO times; a display range passes through unchanged."
  @spec time_range(String.t() | nil, String.t() | nil) :: String.t()
  def time_range(from, to) when is_binary(from) and is_binary(to) do
    with {:ok, from} <- Time.from_iso8601(from),
         {:ok, to} <- Time.from_iso8601(to) do
      Fmt.time_range(from, to)
    else
      _ -> ""
    end
  end

  def time_range(range, nil) when is_binary(range), do: range
  def time_range(_from, _to), do: ""

  @spec money(term()) :: String.t()
  def money(amount), do: Format.money(amount)

  @spec words([String.t() | nil]) :: String.t()
  def words(parts), do: parts |> Enum.reject(&blank?/1) |> Enum.join(" ")

  @doc "`（a，b）` in Chinese, ` (a, b)` in English; `\"\"` when every part is blank."
  @spec paren([String.t() | nil], String.t()) :: String.t()
  def paren(parts, locale) do
    case Enum.reject(parts, &blank?/1) do
      [] -> ""
      kept when locale == "en" -> " (" <> Enum.join(kept, ", ") <> ")"
      kept -> "（" <> Enum.join(kept, "，") <> "）"
    end
  end

  @doc "`10月` / `October` from `YYYY-MM` or an ISO date."
  @spec month_name(String.t() | nil, String.t()) :: String.t()
  def month_name(value, locale) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 7) <> "-01") do
      {:ok, date} when locale == "en" -> Calendar.strftime(date, "%B")
      {:ok, date} -> "#{date.month}月"
      {:error, _} -> ""
    end
  end

  def month_name(_value, _locale), do: ""

  @spec weekday(1..7, String.t()) :: String.t()
  def weekday(n, "en") when n in 1..7, do: Enum.at(@en_weekdays, n - 1)
  def weekday(n, _locale) when n in 1..7, do: Fmt.weekday(n)
  def weekday(_n, _locale), do: ""

  @spec method(String.t() | nil, String.t()) :: String.t() | nil
  def method(nil, _locale), do: nil
  def method("line_pay", _locale), do: "LINE Pay"
  def method("line_bank", _locale), do: "LINE Bank"
  def method("cash", "en"), do: "cash"
  def method("other", "en"), do: "other"
  def method(method, "en"), do: method
  def method(method, _locale), do: Fmt.method(method)

  @doc "A Package kind: 月課程 / 單堂 / 體驗, or monthly / drop-in / trial."
  @spec kind(String.t() | nil, String.t()) :: String.t()
  def kind("monthly", "en"), do: "monthly"
  def kind("drop_in", "en"), do: "drop-in"
  def kind("trial", "en"), do: "trial"
  def kind("monthly", _locale), do: "月課程"
  def kind("drop_in", _locale), do: "單堂"
  def kind("trial", _locale), do: "體驗"
  def kind(other, _locale), do: to_string(other)

  defp blank?(value), do: value in [nil, ""]
end
```

In `lib/ganesha/assistant/task.ex`, add after the `describe/2` callback and list it in `@optional_callbacks` (Task 5 removes `describe/2`):

```elixir
  # The Draft in one chat sentence, built from `parsed` only (chat-first replies spec §1).
  @callback summary(parsed :: map(), locale :: String.t()) :: String.t()
```

```elixir
  @optional_callbacks propose: 2, apply: 2, describe: 2, summary: 2, answer: 2
```

- [ ] **Step 4: Run** — `mix test test/ganesha/assistant/summary_test.exs` — PASS.

- [ ] **Step 5: Commit** — `git add lib/ganesha/assistant/summary.ex lib/ganesha/assistant/task.ex test/ganesha/assistant/summary_test.exs && git commit -m "Add Summary helpers and the summary/2 task callback"`

---

### Task 2: Money summaries — `record_payment`, `confirm_payment`, `override_price`, `save_package`

**Files:**
- Modify: `lib/ganesha/assistant/tasks/{record_payment,confirm_payment,override_price,save_package}.ex`
- Test: the four matching `test/ganesha/assistant/tasks/*_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.Summary` (Task 1).
- Produces: `summary/2` on each module. `describe/2` stays until Task 5.

Parsed keys used (written by each `propose/2` today):
- record_payment: `student_name`, `amount`, `method`, `paid_on` (ISO), `before_owed` (integer or nil).
- confirm_payment: `student_name`, `amount`, `method`, `paid_on`.
- override_price: `student_name`, `package_name`, `custom_amount` (nil = clear), `list_price`, `before_payable`.
- save_package: `mode` (`"create"`/`"update"`), `name`, `kind`, `price_per_class`, `included_makeups`, `active`, `grandfather_strategy`; update also `before_price_per_class`, `before_included_makeups`, `before_active`, `before_grandfather_strategy`.

- [ ] **Step 1: Write failing tests.** Add a `describe "summary/2"` block to each test file:

`record_payment_test.exs`:

```elixir
  describe "summary/2" do
    @summary_parsed %{
      "student_name" => "Amy",
      "amount" => 3200,
      "method" => "line_pay",
      "paid_on" => "2026-10-03",
      "before_owed" => 3200
    }

    test "names who paid, how much, how, when, and what is still owed" do
      for locale <- ["zh-TW", "en"] do
        text = RecordPayment.summary(@summary_parsed, locale)
        assert text =~ "Amy"
        assert text =~ "NT$3,200"
        assert text =~ "LINE Pay"
        assert text =~ "10/3"
        assert text =~ "→ NT$0"
        refute text =~ "%{"
      end
    end

    test "leaves the owed part out when nothing was owed before" do
      text = RecordPayment.summary(%{@summary_parsed | "before_owed" => nil}, "zh-TW")
      refute text =~ "→"
    end
  end
```

`confirm_payment_test.exs`:

```elixir
  describe "summary/2" do
    test "names the student, amount, method and date", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      for locale <- ["zh-TW", "en"] do
        text = ConfirmPayment.summary(parsed, locale)
        assert text =~ "Lulu"
        assert text =~ "NT$800"
        assert text =~ "LINE Pay"
        assert text =~ "10/2"
      end
    end
  end
```

`override_price_test.exs`:

```elixir
  test "summary names the new price and the old one, or the list price when clearing", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    for locale <- ["zh-TW", "en"] do
      text = OverridePrice.summary(parsed, locale)
      assert text =~ "Lulu"
      assert text =~ "月課程"
      assert text =~ "NT$1,500"
      assert text =~ "NT$1,600"
    end

    {:ok, %{parsed: cleared}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => nil}, c.ctx)

    assert OverridePrice.summary(cleared, "zh-TW") =~ "NT$1,600"
  end
```

`save_package_test.exs`:

```elixir
  test "summary describes a new package, and only the changed fields of an edit" do
    create = %{
      "mode" => "create",
      "name" => "晚間單堂",
      "kind" => "drop_in",
      "price_per_class" => 450,
      "included_makeups" => 0,
      "active" => true,
      "grandfather_strategy" => "none"
    }

    for locale <- ["zh-TW", "en"] do
      text = SavePackage.summary(create, locale)
      assert text =~ "晚間單堂"
      assert text =~ "NT$450"
    end

    update = %{
      "mode" => "update",
      "name" => "月課程",
      "kind" => "monthly",
      "price_per_class" => 420,
      "included_makeups" => 1,
      "active" => true,
      "grandfather_strategy" => "none",
      "before_price_per_class" => 400,
      "before_included_makeups" => 1,
      "before_active" => true,
      "before_grandfather_strategy" => "none"
    }

    text = SavePackage.summary(update, "zh-TW")
    assert text =~ "NT$400"
    assert text =~ "NT$420"
    refute text =~ "補課"
  end
```

- [ ] **Step 2: Run** — `mix test test/ganesha/assistant/tasks/record_payment_test.exs test/ganesha/assistant/tasks/confirm_payment_test.exs test/ganesha/assistant/tasks/override_price_test.exs test/ganesha/assistant/tasks/save_package_test.exs` — FAIL (`summary/2` undefined).

- [ ] **Step 3: Implement.** Add `alias Ganesha.Assistant.Summary` to each module and the following `@impl true` functions next to `describe/2`.

`record_payment.ex`:

```elixir
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    amount = parsed["amount"]
    details = Summary.paren([Summary.method(parsed["method"], locale), short(parsed["paid_on"])], locale)
    head = if locale == "en", do: "Record #{Summary.money(amount)} from #{name}", else: "記錄 #{name} 付款 #{Summary.money(amount)}"
    head <> details <> owed(parsed["before_owed"], amount, locale)
  end

  defp owed(before, amount, locale) when is_integer(before) and is_integer(amount) do
    label = if locale == "en", do: "owes", else: "欠款"
    " — #{label} #{Summary.money(before)} → #{Summary.money(max(before - amount, 0))}"
  end

  defp owed(_before, _amount, _locale), do: ""

  defp short(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> GaneshaWeb.Fmt.short_date(date)
      {:error, _} -> nil
    end
  end

  defp short(_iso), do: nil
```

`confirm_payment.ex`:

```elixir
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    amount = Summary.money(parsed["amount"])
    details = Summary.paren([Summary.method(parsed["method"], locale), short(parsed["paid_on"])], locale)

    if locale == "en",
      do: "Confirm #{amount} received from #{name}" <> details,
      else: "確認收到 #{name} 的 #{amount}" <> details
  end

  defp short(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Fmt.short_date(date)
      {:error, _} -> nil
    end
  end

  defp short(_iso), do: nil
```

`override_price.ex`:

```elixir
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    package = parsed["package_name"]
    list = Summary.money(parsed["list_price"])

    case {parsed["custom_amount"], locale} do
      {nil, "en"} -> "Charge #{name} the list price #{list} for #{package}"
      {nil, _} -> "#{name} 的#{package}改回原價 #{list}"
      {amount, "en"} -> "Charge #{name} #{Summary.money(amount)} for #{package} (was #{Summary.money(parsed["before_payable"])})"
      {amount, _} -> "#{name} 的#{package}改收 #{Summary.money(amount)}（原本 #{Summary.money(parsed["before_payable"])}）"
    end
  end
```

`save_package.ex` (reuses its existing `kind_name/2`, `bool_name/2`, `grandfather_name/2`, which Task 5 keeps):

```elixir
  @impl true
  def summary(%{"mode" => "create"} = parsed, locale) do
    price = Summary.money(parsed["price_per_class"])
    makeups = parsed["included_makeups"] || 0

    if locale == "en",
      do: "New package #{parsed["name"]} (#{kind_name(parsed["kind"], "en")}): #{price}/class, #{makeups} makeups",
      else: "新增方案 #{parsed["name"]}（#{kind_name(parsed["kind"], locale)}）每堂 #{price}，含 #{makeups} 次補課"
  end

  def summary(parsed, locale) do
    changes =
      Enum.reject(
        [
          change_text(:price, parsed["before_price_per_class"], parsed["price_per_class"], locale),
          change_text(:makeups, parsed["before_included_makeups"], parsed["included_makeups"], locale),
          change_text(:active, parsed["before_active"], parsed["active"], locale),
          change_text(:grandfather, parsed["before_grandfather_strategy"], parsed["grandfather_strategy"], locale)
        ],
        &is_nil/1
      )

    case {changes, locale} do
      {[], "en"} -> "#{parsed["name"]}: no changes"
      {[], _} -> "#{parsed["name"]}：沒有變更"
      {_, "en"} -> "#{parsed["name"]}: " <> Enum.join(changes, ", ")
      {_, _} -> "#{parsed["name"]}：" <> Enum.join(changes, "、")
    end
  end

  defp change_text(_field, same, same, _locale), do: nil
  defp change_text(:price, from, to, "en"), do: "#{Summary.money(from)} → #{Summary.money(to)}/class"
  defp change_text(:price, from, to, _), do: "每堂 #{Summary.money(from)} → #{Summary.money(to)}"
  defp change_text(:makeups, from, to, "en"), do: "makeups #{from} → #{to}"
  defp change_text(:makeups, from, to, _), do: "補課 #{from} → #{to} 次"
  defp change_text(:active, from, to, "en"), do: "open to new students #{bool_name(from, "en")} → #{bool_name(to, "en")}"
  defp change_text(:active, from, to, locale), do: "開放新學生 #{bool_name(from, locale)} → #{bool_name(to, locale)}"
  defp change_text(:grandfather, from, to, "en"), do: "when closed: #{grandfather_name(from, "en")} → #{grandfather_name(to, "en")}"
  defp change_text(:grandfather, from, to, locale), do: "停用後 #{grandfather_name(from, locale)} → #{grandfather_name(to, locale)}"
```

- [ ] **Step 4: Run** the four files — PASS.

- [ ] **Step 5: Commit** — `git commit -am "Add summary/2 to the money tasks"` (stage only the eight files).

---

### Task 3: Roster summaries — `enroll`, `book_one_off`, `book_makeup`, `set_no_show`, `makeup_request`

**Files:**
- Modify: `lib/ganesha/assistant/tasks/{enroll,book_one_off,book_makeup,set_no_show,makeup_request}.ex`
- Test: the five matching test files

**Interfaces:**
- Consumes: `Summary` (Task 1).
- Produces: `summary/2` on each module.

Parsed keys used:
- enroll: `student_name`, `month` (`YYYY-MM`), `slot_weekday` (1..7), `slot_time` (`19:00–20:15`), `slot_label`, `session_ids`, `custom_amount`, `price`.
- book_one_off: `student_name`, `session_date`, `session_time`, `session_label`, `package_kind`, `custom_amount`, `price`.
- book_makeup: `student_name`, `session_date`, `session_time`, `session_label`.
- set_no_show: `student_name`, `session_date`, `session_label`, `state` (`no_show`/`expected`).
- makeup_request: `student_name` (may be nil), `note`.

- [ ] **Step 1: Write failing tests** (one per file, parsed built inline):

```elixir
  # enroll_test.exs
  test "summary names the student, month, class, count and what is owed" do
    parsed = %{
      "student_name" => "Lulu", "month" => "2026-10", "slot_weekday" => 2,
      "slot_time" => "19:00–20:15", "slot_label" => "基礎",
      "session_ids" => [1, 2, 3, 4], "custom_amount" => nil, "price" => 1600
    }

    for locale <- ["zh-TW", "en"] do
      text = Enroll.summary(parsed, locale)
      for fact <- ["Lulu", "基礎", "19:00–20:15", "4", "NT$1,600"], do: assert(text =~ fact)
    end

    assert Enroll.summary(parsed, "zh-TW") =~ "10月"
    assert Enroll.summary(parsed, "en") =~ "October"
    assert Enroll.summary(%{parsed | "custom_amount" => 1500}, "zh-TW") =~ "NT$1,500"
  end
```

```elixir
  # book_one_off_test.exs
  test "summary names the student, the session, the kind and what is owed" do
    parsed = %{
      "student_name" => "Lulu", "session_date" => "2026-10-08", "session_time" => "19:00–20:15",
      "session_label" => "基礎", "package_kind" => "drop_in", "custom_amount" => nil, "price" => 400
    }

    assert BookOneOff.summary(parsed, "zh-TW") =~ "單堂"
    assert BookOneOff.summary(parsed, "en") =~ "drop-in"

    for locale <- ["zh-TW", "en"] do
      text = BookOneOff.summary(parsed, locale)
      for fact <- ["Lulu", "10/8", "19:00–20:15", "基礎", "NT$400"], do: assert(text =~ fact)
    end
  end
```

```elixir
  # book_makeup_test.exs
  test "summary names the student and the session" do
    parsed = %{
      "student_name" => "Lulu", "session_date" => "2026-10-08",
      "session_time" => "19:00–20:15", "session_label" => "基礎"
    }

    for locale <- ["zh-TW", "en"] do
      text = BookMakeup.summary(parsed, locale)
      for fact <- ["Lulu", "10/8", "19:00–20:15", "基礎"], do: assert(text =~ fact)
    end
  end
```

```elixir
  # set_no_show_test.exs
  test "summary says which way the attendance goes" do
    parsed = %{
      "student_name" => "阿花", "session_date" => "2026-10-02",
      "session_label" => "晚課", "state" => "no_show"
    }

    absent = SetNoShow.summary(parsed, "zh-TW")
    back = SetNoShow.summary(%{parsed | "state" => "expected"}, "zh-TW")

    for text <- [absent, back], fact <- ["阿花", "10/2", "晚課"], do: assert(text =~ fact)
    assert absent =~ "缺席"
    refute back =~ "記為缺席"
    assert SetNoShow.summary(parsed, "en") =~ "absent"
  end
```

```elixir
  # makeup_request_test.exs (replaces the describe/2 test)
  test "summary says who asked and what they asked for" do
    assert MakeupRequest.summary(%{"student_name" => "蘭子", "note" => "想補 8/17"}, "zh-TW") =~ "蘭子"
    assert MakeupRequest.summary(%{"student_name" => "蘭子", "note" => "想補 8/17"}, "zh-TW") =~ "想補 8/17"
    assert MakeupRequest.summary(%{"note" => "8/17"}, "en") =~ "8/17"
  end
```

- [ ] **Step 2: Run** the five files — FAIL.

- [ ] **Step 3: Implement** (add `alias Ganesha.Assistant.Summary` to each):

```elixir
  # enroll.ex
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    month = Summary.month_name(parsed["month"], locale)
    weekday = Summary.weekday(parsed["slot_weekday"], locale)
    count = length(parsed["session_ids"] || [])
    owed = Summary.money(parsed["custom_amount"] || parsed["price"])
    class = Summary.words([weekday, parsed["slot_time"], parsed["slot_label"]])

    if locale == "en",
      do: "Enroll #{name} in #{class} for #{month}: #{count} classes, #{owed}",
      else: "幫 #{name} 報名#{month} #{class}，#{count} 堂 #{owed}"
  end
```

```elixir
  # book_one_off.ex
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    session = Summary.words([Summary.day(parsed["session_date"], locale), parsed["session_time"], parsed["session_label"]])
    kind = Summary.kind(parsed["package_kind"], locale)
    owed = Summary.money(parsed["custom_amount"] || parsed["price"])

    if locale == "en",
      do: "Book #{name} into #{session} as a #{kind}, #{owed}",
      else: "幫 #{name} 排 #{session} #{kind} #{owed}"
  end
```

```elixir
  # book_makeup.ex
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    session = Summary.words([Summary.day(parsed["session_date"], locale), parsed["session_time"], parsed["session_label"]])

    if locale == "en",
      do: "Book #{name} a makeup in #{session} using a credit",
      else: "用 #{name} 的補課券排 #{session} 補課"
  end
```

```elixir
  # set_no_show.ex
  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    session = Summary.words([Summary.day(parsed["session_date"], locale), parsed["session_label"]])

    case {parsed["state"], locale} do
      {"no_show", "en"} -> "Mark #{name} absent from #{session}"
      {"no_show", _} -> "把 #{name} #{session} 記為缺席"
      {_, "en"} -> "Mark #{name} as coming to #{session} again"
      {_, _} -> "#{name} #{session} 改回會來"
    end
  end
```

```elixir
  # makeup_request.ex
  @impl true
  def summary(parsed, "en"),
    do: "#{parsed["student_name"] || "Someone"} asked for a makeup: #{parsed["note"]}"

  def summary(parsed, _locale),
    do: "#{parsed["student_name"] || "有人"}想補課：#{parsed["note"]}"
```

- [ ] **Step 4: Run** the five files — PASS.

- [ ] **Step 5: Commit** — `"Add summary/2 to the roster tasks"`.

---

### Task 4: Schedule and student summaries — `cancel_session`, `set_session_style`, `add_session`, `add_slot`, `copy_month`, `add_student`

**Files:**
- Modify: `lib/ganesha/assistant/tasks/{cancel_session,set_session_style,add_session,add_slot,copy_month,add_student}.ex`
- Test: the six matching test files

**Interfaces:**
- Consumes: `Summary` (Task 1).
- Produces: `summary/2` on each module.

Parsed keys used:
- cancel_session: `session_date`, `session_time`, `session_label`, `reason`, `credit_count`.
- set_session_style: `session_date`, `session_time`, `session_label`, `style`, `before_style`.
- add_session: `date` (ISO), `start_time`/`end_time` (ISO `HH:MM:SS`), `label`, `style`.
- add_slot: `weekday`, `start_time`/`end_time` (ISO), `label`, `month` (ISO date), `session_count`.
- copy_month: `month` (ISO date of the target month), `session_count`.
- add_student: `display_name`, `aliases` (list).

- [ ] **Step 1: Write failing tests:**

```elixir
  # cancel_session_test.exs
  test "summary names the session, the reason and the credits issued" do
    parsed = %{
      "session_date" => "2026-10-08", "session_time" => "19:00–20:15",
      "session_label" => "基礎", "reason" => "颱風假", "credit_count" => 3
    }

    for locale <- ["zh-TW", "en"] do
      text = CancelSession.summary(parsed, locale)
      for fact <- ["10/8", "19:00–20:15", "基礎", "颱風假", "3"], do: assert(text =~ fact)
    end

    refute CancelSession.summary(%{parsed | "credit_count" => 0}, "zh-TW") =~ "補課券"
  end
```

```elixir
  # set_session_style_test.exs
  test "summary names the session and the style before and after" do
    parsed = %{
      "session_date" => "2026-10-08", "session_time" => "19:00–20:15",
      "session_label" => "基礎", "style" => "陰瑜珈", "before_style" => "Hatha"
    }

    for locale <- ["zh-TW", "en"] do
      text = SetSessionStyle.summary(parsed, locale)
      for fact <- ["10/8", "基礎", "陰瑜珈", "Hatha"], do: assert(text =~ fact)
    end
  end
```

```elixir
  # add_session_test.exs
  test "summary names the date, time, label and style" do
    parsed = %{
      "date" => "2026-10-10", "start_time" => "10:00:00", "end_time" => "11:15:00",
      "label" => "週末班", "style" => "流動"
    }

    for locale <- ["zh-TW", "en"] do
      text = AddSession.summary(parsed, locale)
      for fact <- ["10/10", "10:00–11:15", "週末班", "流動"], do: assert(text =~ fact)
    end
  end
```

```elixir
  # add_slot_test.exs
  test "summary names the weekday, time, label, month and how many sessions" do
    parsed = %{
      "weekday" => 1, "start_time" => "09:30:00", "end_time" => "10:45:00",
      "label" => "基礎", "month" => "2026-10-01", "session_count" => 4
    }

    for locale <- ["zh-TW", "en"] do
      text = AddSlot.summary(parsed, locale)
      for fact <- ["9:30–10:45", "基礎", "4"], do: assert(text =~ fact)
    end

    assert AddSlot.summary(parsed, "zh-TW") =~ "週一"
    assert AddSlot.summary(parsed, "en") =~ "October"
  end
```

```elixir
  # copy_month_test.exs
  test "summary names the month and how many sessions it adds" do
    parsed = %{"month" => "2026-11-01", "session_count" => 9}
    assert CopyMonth.summary(parsed, "zh-TW") =~ "11月"
    assert CopyMonth.summary(parsed, "en") =~ "November"
    for locale <- ["zh-TW", "en"], do: assert(CopyMonth.summary(parsed, locale) =~ "9")
  end
```

```elixir
  # add_student_test.exs
  test "summary names the student and any aliases" do
    text = AddStudent.summary(%{"display_name" => "Amy", "aliases" => ["小艾", "艾咪"]}, "zh-TW")
    assert text =~ "Amy"
    assert text =~ "小艾"
    assert text =~ "艾咪"
    refute AddStudent.summary(%{"display_name" => "Amy", "aliases" => []}, "en") =~ "("
  end
```

- [ ] **Step 2: Run** the six files — FAIL.

- [ ] **Step 3: Implement** (add `alias Ganesha.Assistant.Summary`):

```elixir
  # cancel_session.ex
  @impl true
  def summary(parsed, locale) do
    session = Summary.words([Summary.day(parsed["session_date"], locale), parsed["session_time"], parsed["session_label"]])
    reason = Summary.paren([parsed["reason"]], locale)
    credits = credits_text(parsed["credit_count"] || 0, locale)
    head = if locale == "en", do: "Cancel #{session}", else: "停課 #{session}"
    head <> reason <> credits
  end

  defp credits_text(0, _locale), do: ""
  defp credits_text(1, "en"), do: ", 1 student gets a makeup credit"
  defp credits_text(n, "en"), do: ", #{n} students each get a makeup credit"
  defp credits_text(n, _locale), do: "，#{n} 人各得一張補課券"
```

```elixir
  # set_session_style.ex
  @impl true
  def summary(parsed, locale) do
    session = Summary.words([Summary.day(parsed["session_date"], locale), parsed["session_time"], parsed["session_label"]])

    if locale == "en",
      do: "Change #{session} to #{parsed["style"]} (was #{parsed["before_style"]})",
      else: "#{session} 改上 #{parsed["style"]}（原本 #{parsed["before_style"]}）"
  end
```

```elixir
  # add_session.ex
  @impl true
  def summary(parsed, locale) do
    session =
      Summary.words([
        Summary.day(parsed["date"], locale),
        Summary.time_range(parsed["start_time"], parsed["end_time"]),
        parsed["label"]
      ])

    style = Summary.paren([parsed["style"]], locale)
    if locale == "en", do: "Add a class: #{session}" <> style, else: "加開 #{session}" <> style
  end
```

```elixir
  # add_slot.ex
  @impl true
  def summary(parsed, locale) do
    time = Summary.time_range(parsed["start_time"], parsed["end_time"])
    weekday = Summary.weekday(parsed["weekday"], locale)
    month = Summary.month_name(parsed["month"], locale)
    count = parsed["session_count"] || 0

    if locale == "en",
      do: "New weekly class: #{parsed["label"]}, #{weekday} #{time}; #{count} classes in #{month}",
      else: "新增固定班 每#{weekday} #{time} #{parsed["label"]}，#{month} #{count} 堂"
  end
```

```elixir
  # copy_month.ex
  @impl true
  def summary(parsed, locale) do
    month = Summary.month_name(parsed["month"], locale)
    count = parsed["session_count"] || 0

    if locale == "en",
      do: "Schedule #{month} from the weekly classes: #{count} sessions",
      else: "照固定班排 #{month} 課表，共 #{count} 堂"
  end
```

```elixir
  # add_student.ex
  @impl true
  def summary(parsed, locale) do
    aliases = parsed["aliases"] || []

    case {aliases, locale} do
      {[], "en"} -> "Add student #{parsed["display_name"]}"
      {[], _} -> "新增學生 #{parsed["display_name"]}"
      {_, "en"} -> "Add student #{parsed["display_name"]} (aka #{Enum.join(aliases, ", ")})"
      {_, _} -> "新增學生 #{parsed["display_name"]}（別名 #{Enum.join(aliases, "、")}）"
    end
  end
```

- [ ] **Step 4: Run** the six files — PASS.

- [ ] **Step 5: Commit** — `"Add summary/2 to the schedule and student tasks"`.

---

### Task 5: Switch every Draft consumer to the summary; delete `describe/2`

**Files:**
- Modify: `lib/ganesha/assistant.ex`, `lib/ganesha/assistant/task.ex`, `lib/ganesha/line/cards.ex`, `lib/ganesha/line/labels.ex`, `lib/ganesha/assistant/conversation.ex`, `lib/ganesha/assistant/tasks/pending_drafts.ex`, `lib/ganesha_web/live/dashboard_live.ex`, all 15 change task modules
- Test: `test/ganesha/line/cards_test.exs`, `test/ganesha/assistant/conversation_test.exs`, `test/ganesha/assistant/process_event_worker_test.exs`, `test/ganesha/line/labels_test.exs`, all 15 change task test files

**Interfaces:**
- Consumes: `summary/2` on all 15 tasks (Tasks 2–4).
- Produces: `Assistant.draft_summary(Draft.t(), String.t()) :: String.t()`; `Cards.draft_bubble(Draft.t(), String.t()) :: map()`; `Labels.failure_reason(term(), String.t()) :: String.t()`. `describe/2` and `Assistant.describe_draft/2` no longer exist.

- [ ] **Step 1: Write failing tests.**

In `test/ganesha/line/cards_test.exs`, replace the Draft-card tests with:

```elixir
  describe "draft_bubble/2" do
    test "the body is the Draft's summary and the footer is exactly Confirm and Discard" do
      {:ok, thread} = Ganesha.Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Ganesha.Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

      bubble = Cards.draft_bubble(draft, "zh-TW")

      assert [%{text: text}] = bubble.body.contents
      assert text == Ganesha.Assistant.draft_summary(draft, "zh-TW")
      refute Map.has_key?(bubble, :header)

      assert Enum.map(bubble.footer.contents, & &1.action.data) == [
               "action=confirm&draft_id=#{draft.id}",
               "action=discard&draft_id=#{draft.id}"
             ]
    end
  end
```

(`cards_test.exs` must `use Ganesha.DataCase` for this block.)

In `test/ganesha/line/labels_test.exs` add:

```elixir
  test "stored failure reasons read as a sentence, never as an error code" do
    for reason <- ~w(purchase_changed attendance_changed package_changed payment_not_claimed
                     credit_already_consumed session_cancelled not_found boom),
        locale <- ["zh-TW", "en"] do
      refute Labels.failure_reason(reason, locale) =~ "_"
    end

    assert Labels.failure_reason("purchase_changed", "zh-TW") ==
             Labels.failure_reason("attendance_changed", "zh-TW")

    assert Labels.failure_reason("amount: must be greater than 0", "zh-TW") ==
             "amount: must be greater than 0"
  end
```

In `conversation_test.exs`: replace `defp title(draft, locale), do: Assistant.describe_draft(draft, locale).title` with `defp title(draft, locale), do: Assistant.draft_summary(draft, locale)`, and add to `describe "handle_postback/4"`:

```elixir
    test "a stale Draft fails with a readable reason, not the error code", %{thread: thread} do
      {:ok, student} = People.create_student(%{display_name: "Amy"})
      {:ok, pkg} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})
      {:ok, purchase} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

      {:ok, %{parsed: parsed}} =
        Ganesha.Assistant.Tasks.OverridePrice.propose(
          %{"purchase_id" => purchase.id, "custom_amount" => 1500},
          %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}
        )

      {:ok, draft} = Assistant.create_draft(thread, %{kind: "override_price", parsed: parsed})
      {:ok, _} = Sales.update_purchase(purchase, %{custom_amount: 1400})

      :ok = Conversation.handle_postback(thread, "action=confirm&draft_id=#{draft.id}", "rt-1", @teacher)

      assert [{:reply, {"rt-1", [%{text: text}]}}] = LineMock.calls()
      refute text =~ "purchase_changed"
      assert text =~ Labels.failure_reason(:purchase_changed, "zh-TW")
    end
```

(Alias `Catalog`, `People`, `Sales` if the file does not already; match the existing `handle_postback/4` call shape used by the neighbouring tests in that file.)

In `process_event_worker_test.exs` line 134: `Labels.t(:confirmed, "zh-TW", title: Assistant.draft_summary(draft, "zh-TW"))`.

In each of the 15 change task test files, **delete** every test that calls `describe/2` (the `summary/2` tests from Tasks 2–4 replace them).

- [ ] **Step 2: Run** — `mix test test/ganesha/line test/ganesha/assistant/conversation_test.exs` — FAIL.

- [ ] **Step 3: Implement.**

`lib/ganesha/assistant.ex` — replace `describe_draft/2`:

```elixir
  @doc """
  The Draft in one chat sentence, from its task's `summary/2`. A Draft of a
  retired kind (kept as history) falls back to its kind.
  """
  def draft_summary(%Draft{kind: kind, parsed: parsed}, locale) do
    case Tasks.fetch(kind) do
      {:ok, task} -> task.summary(parsed || %{}, locale)
      :error -> kind
    end
  end
```

`lib/ganesha/assistant/task.ex` — delete the `describe/2` callback and its `@callback` block; moduledoc line becomes `:change tasks implement propose/2, apply/2 and summary/2`, the bullet `describe/2 reads only parsed` becomes `summary/2 reads only parsed; it never queries current data`; `@optional_callbacks propose: 2, apply: 2, summary: 2, answer: 2`.

Each of the 15 change tasks — delete `describe/2` and every private helper only it called (`label/2`, `line/3`, `change/4`, `title/…`, `*_line/…`, `state_name/2`, `date_text/2`, `method_name/2`, `roster_change/2`, `owed_change/3`, `month_path/1`, `expiry_text/2`, `credit_source/1`, `session_line/3`, `kind_line/2`, etc.). Keep helpers `propose/2`, `apply/2` or `summary/2` still call (`save_package` keeps `kind_name/2`, `bool_name/2`, `grandfather_name/2`; `add_session` / `add_slot` keep `parse_time` and `build_attrs`). `mix compile --warnings-as-errors` flags each leftover as an unused function — delete until clean. Remove aliases that become unused.

`lib/ganesha/line/labels.ex` — add labels and a function; change outcome texts:

```elixir
    confirmed: {"好，已記錄：%{title}", "Done: %{title}"},
    discarded: {"已捨棄：%{title}", "Discarded: %{title}"},
    failed: {"沒辦法套用：%{title}（%{reason}）", "Couldn't apply: %{title} (%{reason})"},
    reason_changed: {"資料已經變了，請再跟我說一次", "the data changed since; please ask me again"},
    reason_not_found: {"找不到相關資料了", "the record is gone"},
    reason_other: {"系統沒辦法完成這筆", "the system couldn't complete it"},
```

```elixir
  @changed ~w(purchase_changed attendance_changed package_changed payment_not_claimed
              credit_already_consumed session_cancelled)

  @doc """
  A Draft's stored `failure_reason` as she should read it (chat-first replies
  spec §2). Stored reasons are atom names or a changeset's `field: message`
  text (`Assistant.failure_reason/1`); the latter is already readable.
  """
  @spec failure_reason(String.t() | nil, String.t() | nil) :: String.t()
  def failure_reason(reason, locale) when reason in @changed, do: t(:reason_changed, locale)
  def failure_reason("not_found", locale), do: t(:reason_not_found, locale)

  def failure_reason(reason, locale) when is_binary(reason) do
    if String.contains?(reason, ": "), do: reason, else: t(:reason_other, locale)
  end

  def failure_reason(_reason, locale), do: t(:reason_other, locale)
```

Add the three new keys to `@keys` in `labels_test.exs`.

`lib/ganesha/assistant/conversation.ex` — replace `describe_outcome/2` and `outcome_text(:failed, …)`:

```elixir
  defp describe_outcome({status, draft}, locale) do
    title = Assistant.draft_summary(draft, locale)
    {outcome_text(status, draft, title, locale), history_line(status, draft, title, locale)}
  end
```

```elixir
  defp outcome_text(:failed, draft, title, locale),
    do: Labels.t(:failed, locale, title: title, reason: Labels.failure_reason(draft.failure_reason, locale))
```

(`history_line/4` keeps the raw `draft.failure_reason` for the model.)

`lib/ganesha/line/cards.ex` — replace `render({:draft, …})`, `footer/3`, `web_button/2`, `put_body/2`, `change_line/1` with:

```elixir
  @doc "A Draft as one sentence with 確認 / 捨棄 (chat-first replies spec §2)."
  @spec draft_bubble(Draft.t(), String.t()) :: map()
  def draft_bubble(%Draft{} = draft, locale) do
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
        layout: "horizontal",
        spacing: "sm",
        contents: [
          button("primary", %{type: "postback", label: Labels.t(:confirm, locale), data: "action=confirm&draft_id=#{draft.id}"}),
          button("secondary", %{type: "postback", label: Labels.t(:discard, locale), data: "action=discard&draft_id=#{draft.id}"})
        ]
      }
    }
  end
```

`draft_carousel/2` maps `&draft_bubble(&1, locale)`; `history_line({:draft, draft}, locale)` uses `Assistant.draft_summary(draft, locale)`. Delete the `open_web` label.

`lib/ganesha/assistant/tasks/pending_drafts.ex` — `data/2` lines become `Enum.map(drafts, &"##{&1.id} #{Assistant.draft_summary(&1, locale)}")`; drop the `Cards` alias. Update `pending_drafts_test.exs` to assert `data =~ Assistant.draft_summary(draft, "zh-TW")`.

`lib/ganesha_web/live/dashboard_live.ex` — `{Assistant.draft_summary(draft, "zh-TW")}` replaces `{Assistant.describe_draft(draft, "zh-TW").title}`.

`lib/ganesha/assistant/task.ex` — `summary/2` stays in `@optional_callbacks` (lookup and control tasks don't implement it).

- [ ] **Step 4: Run** — `mix compile --warnings-as-errors && mix test` — PASS.

- [ ] **Step 5: Commit** — `"Show Drafts as one sentence with Confirm/Discard; readable failure reasons"`.

---

### Task 6: Lookups answer in text only

**Files:**
- Modify: `lib/ganesha/assistant/task.ex`, `turn.ex`, `agent.ex`, `tasks.ex`, `lib/ganesha/line/reply.ex`, `lib/ganesha/line/cards.ex`, `lib/ganesha/line/labels.ex`, `lib/ganesha/assistant/conversation.ex`, `lib/ganesha/assistant/tasks/{next_session,session_roster,month_schedule,month_money,student_summary,open_credits,lookup}.ex`, `lib/mix/tasks/line.validate_cards.ex`
- Test: `agent_test.exs`, `tasks_test.exs`, `reply_test.exs`, `cards_test.exs`, `labels_test.exs`, `conversation_test.exs`, six lookup task tests

**Interfaces:**
- Produces: `answer/2 :: {:ok, %{required(:data) => String.t(), optional(:choices) => [String.t()], optional(:draft_ids) => [integer()]}} | {:error, String.t()}`; `%Turn{text, draft_ids, choices, reply_message_id}` (no `cards`); `Reply.build/3` and `Reply.history_text/3` unchanged signatures.

- [ ] **Step 1: Write failing tests.**

`tasks_test.exs` — replace the `show_card` assertions in "tool_schemas/1 …" with:

```elixir
    assert lookup.name == "lookup_thing"
    assert lookup.input_schema == Lookup.tool().input_schema
    refute Map.has_key?(lookup.input_schema.properties, :show_card)
```

Add:

```elixir
  test "no lookup offers show_card" do
    for task <- Tasks.for_chat(:teacher), task.kind() == :lookup do
      [schema] = Tasks.tool_schemas([task])
      refute Map.has_key?(schema.input_schema.properties, :show_card)
    end
  end
```

`reply_test.exs` — delete lookup-card tests; keep/adjust: text → carousel → chips order; 13 Drafts → 12 bubbles + `more_drafts` text; every message count ≤ 3.

`conversation_test.exs` — replace "a lookup with show_card true replies with its card…" with:

```elixir
    test "a lookup answer arrives as text only", %{thread: thread} do
      model([%{id: "t1", name: "next_session", input: %{}}], "下一堂是週四 19:00 基礎。")

      :ok = Conversation.handle_message(say(thread, "下一堂？"), "rt-1", @teacher)

      assert [{:loading, _}, {:reply, {"rt-1", messages}}] = LineMock.calls()
      assert Enum.all?(messages, &(&1.type == "text"))
    end
```

Each lookup test (`next_session`, `session_roster`, `month_schedule`, `month_money`, `student_summary`, `open_credits`): change `assert {:ok, %{data: data, card: {…, payload}}} = …` to `assert {:ok, %{data: data} = answer} = …`, add `refute Map.has_key?(answer, :card)`, and delete payload assertions. Where a payload assertion covered a fact not yet in `data` (e.g. month_money revenue, tax warning; open_credits count), assert it on `data` instead and extend `data` in Step 3 if it fails.

`agent_test.exs` — delete "a lookup's card is kept only when show_card is true"; `Echo.answer/2` returns `{:ok, %{data: "echoed: #{text}"}}`.

- [ ] **Step 2: Run** — `mix test test/ganesha/assistant test/ganesha/line` — FAIL.

- [ ] **Step 3: Implement.**
  - `task.ex`: drop `@type card`, drop `optional(:card)` from `answer/2`.
  - `turn.ex`: remove `cards` from the struct, typespec and moduledoc.
  - `agent.ex` `run_task(:lookup, …)`:

```elixir
  defp run_task(:lookup, task, input, %Turn{} = turn, ctx) do
    case task.answer(input, ctx) do
      {:ok, %{data: data} = answer} ->
        listed = Map.get(answer, :draft_ids, []) -- turn.draft_ids
        {data, %Turn{turn | draft_ids: turn.draft_ids ++ listed}}

      {:error, text} ->
        {text, turn}
    end
  end
```

  Moduledoc: `:lookup → answer/2; optional draft_ids are merged onto the Turn (deduped)`.
  - `tasks.ex`: `defp add_shared_fields(schema, :lookup), do: schema`.
  - `reply.ex`:

```elixir
  @moduledoc """
  Packs a `Ganesha.Assistant.Turn` into LINE messages (chat-first replies spec §2):
  the text, then one Draft carousel. Drafts past twelve are counted in the text.
  Choices ride on the last message as quick replies.
  """

  @spec build(Turn.t(), [Draft.t()], String.t()) :: [map()]
  def build(%Turn{} = turn, drafts, locale) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)
    texts = case text(turn.text, length(hidden), locale) do
      nil -> []
      text -> [Client.text_message(text)]
    end

    carousel =
      case shown do
        [] -> []
        shown ->
          alt_text = Enum.map_join(shown, "\n", &Assistant.draft_summary(&1, locale))
          [Client.flex_message(String.slice(alt_text, 0, 400), Cards.draft_carousel(shown, locale))]
      end

    attach_choices(texts ++ carousel, turn.choices, locale)
  end

  @spec history_text(Turn.t(), [Draft.t()], String.t()) :: String.t() | nil
  def history_text(%Turn{} = turn, drafts, locale) do
    lines = Enum.map(drafts, &Cards.history_line({:draft, &1}, locale)) ++ choices_line(turn.choices, locale)
    if lines == [], do: nil, else: Enum.join(lines, "\n")
  end
```

  Delete `plan/3` and `@max_messages`; alias `Ganesha.Assistant`. (LINE caps Flex `altText` at 400 characters; the slice keeps a 12-Draft carousel valid.)
  - `cards.ex`: delete every lookup `render/2` clause, lookup `history_line/2` clauses, `samples/1`, `session_lines`, `attendee_line`, `month_lines`, `money_lines`, `student_lines`, `section`, `credits_lines`, `credit_line`, `capped`, `kind_label`, `present`, `lookup_bubble`, `body_box`, `text/2`, `@max_rows`, `@max_attendees`, `Format` alias. Moduledoc: "The Draft card (chat-first replies spec §2): one sentence and 確認 / 捨棄."
  - `labels.ex`: delete labels used only by removed cards — `card_session card_month card_money card_student card_credits more_rows cancelled roster_count no_one_booked no_show kind_enrolled kind_makeup kind_drop_in kind_trial schedule_title sessions_count booked_count no_sessions money_title revenue tax_threshold tax_warn owed_total nothing_owed owes paid_up purchases paid_of upcoming credits_heading source_package source_cancellation expires_on no_expiry credits_title credits_count no_credits`. Before deleting each, `grep -rn ":<key>" lib` must show no other user. Remove them from `@keys` in `labels_test.exs`.
  - Lookup tasks: return `{:ok, %{data: data}}`; delete `card:` and the payload builders (`Lookup.session_payload/3`, `Lookup.attendee_payload/1`, and the money/student/credits/month payload functions). Remove "Use show_card …" sentences from each `tool/0` description.
  - `conversation.ex`: `record_cards/2` and `text_only/3` keep working (they use `Reply.history_text/3` and Draft history lines); remove any reference to `turn.cards`.
  - `line.validate_cards.ex`: checks become one Draft carousel per locale built from an unsaved `%Draft{id: 1, kind: "makeup_request", parsed: %{"student_name" => "Amy", "note" => "8/17"}}`, plus `choices_message/0`:

```elixir
  defp locale_checks(locale) do
    draft = %Ganesha.Assistant.Draft{id: 1, kind: "makeup_request", parsed: %{"student_name" => "Amy", "note" => "8/17"}}
    alt = Ganesha.Assistant.draft_summary(draft, locale)
    [{"#{locale} draft carousel", [Client.flex_message(alt, Cards.draft_carousel([draft], locale))]}]
  end
```

  Delete `check/3`; moduledoc "Validates the Draft card and choice chips against the Messaging API."

- [ ] **Step 4: Run** — `mix compile --warnings-as-errors && mix test` — PASS.

- [ ] **Step 5: Commit** — `"Answer lookups in text only; remove lookup cards and show_card"`.

---

### Task 7: Teacher prompt reply rules

**Files:**
- Modify: `lib/ganesha/assistant/prompts.ex`
- Test: `test/ganesha/assistant/prompts_test.exs`

**Interfaces:**
- Consumes: none. Produces: `Prompts.teacher/…` text (signature unchanged).

- [ ] **Step 1: Write failing test** in `prompts_test.exs`:

```elixir
  test "the teacher prompt never asks for cards and forbids markdown" do
    prompt = Prompts.teacher("zh-TW", nil)
    refute prompt =~ "show_card"
    assert prompt =~ "markdown"
  end
```

(Use the existing teacher-prompt function name and arity already exercised in this test file.)

- [ ] **Step 2: Run** — FAIL (`show_card` is in rule 8).

- [ ] **Step 3: Implement.** In `teacher_rules/0` replace rules 5, 6 and 8 with (renumber):

```
5. Draft cards with Confirm and Discard buttons are shown under your reply automatically. \
After proposing a change, say in one short line that something is waiting for her to \
confirm; never repeat the card's details.
6. Lines in square brackets such as "[草稿 #41 待確認] …" or "[已確認] 草稿 #41 …" are \
added by the system to record the Drafts and buttons she saw; she did not type them. \
Never write such a bracketed line yourself.
8. Answering questions: call the matching lookup (next_session, month_schedule, \
session_roster, student_summary, month_money, open_credits) and answer in a few short \
lines of plain chat. Lead with the answer itself. For long lists give the first five or \
so, say how many more there are, and offer the rest. Copy numbers, names and dates \
exactly as the tool returned them; never compute totals the tool didn't give.
9. Plain text only: no markdown (no **, #, tables or bullet syntax). LINE shows it raw.
```

- [ ] **Step 4: Run** — `mix test test/ganesha/assistant/prompts_test.exs test/ganesha/assistant/conversation_test.exs` — PASS.

- [ ] **Step 5: Commit** — `"Teacher prompt: chat-first reply rules"`.

---

### Task 8: Smoke, real-model runs, precommit

**Files:**
- Modify: `priv/scripts/line_smoke.exs`, `priv/scripts/line_real_questions.exs`

- [ ] **Step 1: Update `line_smoke.exs`.**
  - Step 3: replace the 確認 / 捨棄 label assertion with the postback assertion it already makes; the "records the card it sent" check compares against `"[草稿 ##{draft.id} 待確認] " <> Assistant.draft_summary(draft, "zh-TW")`.
  - Step 5 outcome check: `outcome_texts == [Labels.t(:confirmed, "zh-TW", title: Assistant.draft_summary(draft, "zh-TW"))]`.
  - Step 7: stub `next_session` with `%{}` input (no `show_card`); replace the Flex-bubble checks with:

```elixir
Smoke.check(
  "the answer to a question is text only",
  question_replies |> List.first([]) |> Enum.all?(&(&1.type == "text"))
)
```

  and drop the card-title / "records the session card" checks.
  - Every `Cards.history_line({:draft, d}, "zh-TW")` usage stays valid.

- [ ] **Step 2: Update `line_real_questions.exs`** — drop any `show_card` input or card printing; print the reply texts. Then run it.

- [ ] **Step 3: Run checks.**

```bash
mix precommit
mix run priv/scripts/line_smoke.exs
source .env.dev && mix line.validate_cards
source .env.dev && for s in payment enroll no_show; do mix run priv/scripts/line_real_turn.exs $s; done
source .env.dev && mix run priv/scripts/line_real_questions.exs
```

Expected: precommit 0 failures; smoke ALL CHECKS PASSED; validate_cards all PASS; each real turn prints one pending Draft whose card body is one sentence; real questions print short plain-text answers with no `**` or `#`.

- [ ] **Step 4: Commit** — `"Smoke and real-model scripts for chat-first replies"`.

---

## Self-review notes

- Spec §1 (contract, all 15 sentences) → Tasks 1–5. §2 (card, carousel, order, outcomes, readable reasons, history, push, dashboard) → Task 5 (+ Reply in Task 6; push uses `Cards.draft_carousel`, unchanged call). §3 (lookups text-only, prompt) → Tasks 6–7. §4 (removals) → Tasks 5–6. §5 (testing) → every task + Task 8.
- `GroupDraftNotifier` needs no code change: it calls `Cards.history_line/2` and `Cards.draft_carousel/2`, both kept with the same signatures.
