# LINE Teacher Assistant — Slice 1 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the LINE assistant's eight lookup/draft tools with whole-task modules behind a `Ganesha.Assistant.Task` behaviour, give every Draft a confirm-time re-check with `failed` and `replaced` outcomes, answer the teacher with fixed Flex Draft cards, and give the Teacher chat three levels of memory.

**Architecture:** `Ganesha.Assistant.Agent.run/4` loops over task modules (`Ganesha.Assistant.Tasks.*`), dispatching by kind (`:change` → `propose/2` + `Assistant.create_draft/3`, `:lookup`/`:control` → `answer/2`) and returning a `Ganesha.Assistant.Turn`. `Ganesha.Assistant.Conversation` (extracted from `ProcessEventWorker`) builds the prompt from `Prompts` + `Snapshot` + `Memory`, runs the agent, packs the Turn into ≤ 5 LINE messages with `Ganesha.Line.Reply`/`Cards`/`Labels`, and handles Confirm/Discard postbacks through `Assistant.confirm_draft/2`, which re-runs the task's `apply/2` through the domain functions inside one transaction. A nightly `DigestWorker` writes daily/weekly digests for the Teacher chat.

**Tech Stack:** Elixir 1.20, Phoenix 1.8.13, Ecto + `ecto_sqlite3` (SQLite), Oban 2.24 (`Oban.Engines.Lite`, cron plugin), `Req` 0.7 (with `Req.Test` stubs) for the LINE Messaging API and the Anthropic Messages API. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md` — this plan implements slice 1 of §9 ("Foundation"). Also read `GLOSSARY.md` (vocabulary) and `docs/adr/0001-every-line-write-is-a-draft.md`, `0002-line-tools-are-use-cases.md`, `0003-group-chat-text-is-never-summarized.md`.

## Global Constraints

Spec §2 rules, verbatim:

1. Every ledger change requested in LINE becomes a Draft; only the teacher's Confirm applies it (ADR 0001). The language setting is not a ledger change and applies immediately.
2. Confirm re-runs the change through the same domain functions the web UI calls. A change that no longer fits fails with a reason; nothing is written.
3. A correction replaces the earlier Draft (`replaced`), so one fact never has two live Drafts.
4. Tools are whole tasks, not copies of web-screen buttons (ADR 0002). The model gets a studio snapshot with every message instead of looking things up step by step.
5. When the model cannot decide (two students named Amy, two Tuesday Slots), it asks with quick-reply options instead of guessing.
6. Cards are a fixed set designed in code. The model picks a card; it never lays one out or writes its numbers. A Draft card shows only the Draft's stored values.
7. The Teacher chat gets every task. The Group chat gets three: record payment, single-class/trial booking, makeup request. Student chats get none (only `set_language`).

Values and contracts (spec §3–§7):

- Model: Claude Sonnet 5.5 (`claude-sonnet-5-5`, overridable with `ANTHROPIC_MODEL`) — already wired in `config/runtime.exs`; do not change.
- Agent limits: 6 rounds (`{:error, :max_iterations_exceeded}` after), `max_tokens: 4096` in `Provider.Anthropic`.
- Agent tool results: `"draft #<id> created (<name>, pending confirmation)"`; unknown tool → `"unknown tool: <name>"`.
- `ask_teacher(question, options[])` — 2–13 options, each ≤ 20 characters, sent as quick-reply buttons that send their text back as a normal message.
- `set_language(locale)` — `zh-TW` or `en`. Teacher chat and Student chats.
- Draft `state`: `pending | applied | discarded | replaced | failed`; all but `pending` final. New columns `failure_reason :string`, `replaced_by_id :integer` (references `drafts`), `notified_at :utc_datetime`; new index `[:state, :thread_id]`.
- Draft `kind` is the task `name`, validated with `Tasks.fetch/1` on insert only.
- `failure_reason`: an atom name, or the changeset's errors joined as `field: message`.
- Reply: ≤ 5 messages; order text → lookup cards → one Draft carousel; ≤ 12 bubbles per carousel; every Flex message has `altText` ≤ 400 characters; choices become a `quickReply` on the last message.
- Draft card: header = `describe/2` title; body = `lines`, then each change as `label: before → after` (or `label: after` when `before` is nil); footer = 確認/捨棄 postback buttons (`action=confirm&draft_id=<id>`, `action=discard&draft_id=<id>`) and, when `web_path` is set, a URI button to `GaneshaWeb.Endpoint.url() <> web_path`.
- Loading animation: `Line.Client.loading(source_id, 20)` before every 1:1 turn (`POST /v2/bot/chat/loading/start` with `chatId`, `loadingSeconds`).
- §6.3 outcome texts (zh-TW / en) exactly as in the spec table; the outcome is also appended to the Teacher chat as an assistant message, e.g. `[已確認] 草稿 #41 收款 Amy NT$3,200`.
- Memory (§6.4): counted message = role `user`, or role `assistant` with no tool calls; Level 1 = last 30 counted (all of today's Asia/Taipei when > 30, up to 100), always starting at a `user` message; Student chats last 30 counted only; Level 3 = `weekly` digests with `period_end` ≥ 15 days before today and `period_start` within 90 days; Level 2 = `daily` digests after the newest Level 3 week (or within the last 14 days when none) up to and including the oldest Level 1 message's date; `DigestWorker` cron `{"30 16 * * *", Ganesha.Assistant.DigestWorker}`; 90-day window; unsend/edit of a Teacher chat message deletes that date's daily digest and the weekly digest containing it; Group chat and Student chats get no digests (ADR 0003).
- Removed in this slice: `Ganesha.Assistant.Tool`, every module in `lib/ganesha/assistant/tools/` (and `test/ganesha/assistant/tools/`), `Assistant.tools/0`, `Assistant.apply_draft/2`.

Project rules (`AGENTS.md`):

- Generate every migration with `mix ecto.gen.migration <name_with_underscores>`, then fill in the generated file.
- Tests: `Ganesha.DataCase` with inline fixtures (no factories); start processes with `start_supervised!/1`; never `Process.sleep/1`.
- Every task ends with `mix compile --warnings-as-errors` clean and the task's test files green. Run `mix precommit` only in Task 16.
- Never write `alias Ganesha.Assistant.Task` or `alias Ganesha.Assistant.{Task, …}`: it would shadow Elixir's `Task`. Always spell the behaviour out: `@behaviour Ganesha.Assistant.Task`.
- `after` is a reserved word in Elixir; the spec's `describe/2` typespec uses `after_value` instead (see Task 1).

## File Structure

Created:

| File | Responsibility |
|---|---|
| `lib/ganesha/assistant/task.ex` | `Ganesha.Assistant.Task` behaviour (§4.2). |
| `lib/ganesha/assistant/turn.ex` | `Ganesha.Assistant.Turn` struct. |
| `lib/ganesha/assistant/tasks.ex` | Registry: `for_chat/1`, `fetch/1`, `tool_schemas/1`. |
| `lib/ganesha/assistant/tasks/record_payment.ex` | `record_payment` change task. |
| `lib/ganesha/assistant/tasks/book_one_off.ex` | `book_one_off` change task. |
| `lib/ganesha/assistant/tasks/makeup_request.ex` | `makeup_request` change task. |
| `lib/ganesha/assistant/tasks/ask_teacher.ex` | `ask_teacher` control tool. |
| `lib/ganesha/assistant/tasks/set_language.ex` | `set_language` control tool. |
| `lib/ganesha/assistant/prompts.ex` | System prompts (moved out of `Ganesha.Assistant`). |
| `lib/ganesha/assistant/snapshot.ex` | Studio snapshot text. |
| `lib/ganesha/assistant/memory.ex` | Level 1 window, Level 2/3 summaries, digest writing and invalidation. |
| `lib/ganesha/assistant/digest.ex` | `assistant_digests` schema. |
| `lib/ganesha/assistant/digest_worker.ex` | Nightly Oban cron job. |
| `lib/ganesha/assistant/conversation.ex` | 1:1 turn and postback end to end. |
| `lib/ganesha/line/labels.ex` | Card, button and outcome labels per locale. |
| `lib/ganesha/line/cards.ex` | Draft card, Draft carousel, history lines. |
| `lib/ganesha/line/reply.ex` | Packs a `Turn` into ≤ 5 LINE messages. |
| `priv/repo/migrations/<ts>_extend_drafts_for_tasks.exs` | Draft columns, index, data migration. |
| `priv/repo/migrations/<ts>_create_assistant_digests.exs` | `assistant_digests` table. |
| `priv/scripts/line_real_turn.exs` | One real Sonnet turn through `Conversation` with `Line.Client.Mock`. |

Modified: `lib/ganesha/assistant.ex` (Draft lifecycle, helpers; prompts and tools removed), `lib/ganesha/assistant/draft.ex`, `lib/ganesha/assistant/thread.ex`, `lib/ganesha/assistant/message.ex`, `lib/ganesha/assistant/agent.ex` (rewrite), `lib/ganesha/assistant/process_event_worker.ex` (slimmed to routing), `lib/ganesha/assistant/provider/anthropic.ex` (`max_tokens`), `lib/ganesha/line/client.ex`, `lib/ganesha/line/client_behaviour.ex`, `lib/ganesha/line/client/mock.ex`, `lib/ganesha/people.ex`, `lib/ganesha/studio.ex`, `lib/ganesha/catalog.ex` (non-raising getters), `config/config.exs` (cron), `config/test.exs` (`Req.Test` plug), `priv/scripts/line_smoke.exs`.

Deleted: `lib/ganesha/assistant/tool.ex`, `lib/ganesha/assistant/tools/*.ex` (8 files), `test/ganesha/assistant/tools/*.exs` (8 files).

Task order and why: task modules (1–4) need nothing new; the registry (5) lists them; the Draft lifecycle (6) validates kinds against the registry; the Agent (7) creates Drafts through it; prompts/snapshot (8), LINE plumbing (9–11) and memory (12) are leaves that `Conversation` (13) wires together; digest writing (14) hooks into the slimmed worker; smoke scripts (15–16) prove the whole flow.

---

### Task 1: `Task` behaviour, `Turn`, and the two control tools

**Files:**
- Create: `lib/ganesha/assistant/task.ex`
- Create: `lib/ganesha/assistant/turn.ex`
- Create: `lib/ganesha/assistant/tasks/ask_teacher.ex`
- Create: `lib/ganesha/assistant/tasks/set_language.ex`
- Modify: `lib/ganesha/assistant/thread.ex` (add `@type t`)
- Test: `test/ganesha/assistant/tasks/ask_teacher_test.exs`, `test/ganesha/assistant/tasks/set_language_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.set_locale(thread, locale) :: {:ok, Thread.t()} | {:error, :invalid_locale | Ecto.Changeset.t()}` (exists).
- Produces:
  - `Ganesha.Assistant.Task` behaviour: `name/0 :: String.t()`, `kind/0 :: :lookup | :change | :control`, `tool/0 :: %{description: String.t(), input_schema: map()}`, optional `propose/2`, `apply/2`, `describe/2`, `answer/2` with the §4.2 types; `@type ctx :: %{thread: Thread.t(), locale: String.t(), today: Date.t()}`; `@type card :: {atom(), term()}`.
  - `%Ganesha.Assistant.Turn{text: String.t() | nil, draft_ids: [integer()], cards: [card()], choices: [String.t()]}` (defaults `nil, [], [], []`), `@type t`.
  - `Ganesha.Assistant.Tasks.AskTeacher` — `name() == "ask_teacher"`, `kind() == :control`, `answer(%{"question" => q, "options" => opts}, ctx) :: {:ok, %{data: String.t(), choices: [String.t()]}} | {:error, String.t()}`.
  - `Ganesha.Assistant.Tasks.SetLanguage` — `name() == "set_language"`, `kind() == :control`, `answer(%{"locale" => l}, %{thread: thread}) :: {:ok, %{data: String.t()}} | {:error, String.t()}`; updates `thread.locale` immediately.
  - `Ganesha.Assistant.Thread.t()` type.

- [ ] **Step 1: Write the failing tests**

`test/ganesha/assistant/tasks/ask_teacher_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.AskTeacherTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Tasks.AskTeacher

  test "turns the options into choices for quick-reply buttons" do
    assert {:ok, %{data: data, choices: ["週二晚班", "週四早班"]}} =
             AskTeacher.answer(
               %{"question" => "哪一位 Amy？", "options" => ["週二晚班", "週四早班"]},
               %{}
             )

    assert data =~ "週二晚班 / 週四早班"
  end

  test "accepts 13 options of 20 characters each" do
    options = for n <- 1..13, do: String.pad_leading("#{n}", 20, "選")

    assert {:ok, %{choices: ^options}} =
             AskTeacher.answer(%{"question" => "哪一堂？", "options" => options}, %{})
  end

  test "rejects fewer than 2 or more than 13 options" do
    assert {:error, message} =
             AskTeacher.answer(%{"question" => "哪一個？", "options" => ["只有一個"]}, %{})

    assert message =~ "2–13 options"

    many = for n <- 1..14, do: "選項#{n}"
    assert {:error, _} = AskTeacher.answer(%{"question" => "哪一個？", "options" => many}, %{})
  end

  test "rejects an option longer than 20 characters" do
    long = String.duplicate("長", 21)
    assert {:error, _} = AskTeacher.answer(%{"question" => "哪一個？", "options" => ["短", long]}, %{})
  end

  test "rejects a call without a question" do
    assert {:error, _} = AskTeacher.answer(%{"options" => ["A", "B"]}, %{})
  end
end
```

`test/ganesha/assistant/tasks/set_language_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.SetLanguageTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tasks.SetLanguage

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
    %{thread: thread, ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "switches the chat's language at once and confirms in the new language", %{
    thread: thread,
    ctx: ctx
  } do
    assert {:ok, %{data: "Language switched to English."}} =
             SetLanguage.answer(%{"locale" => "en"}, ctx)

    assert Repo.reload!(thread).locale == "en"
  end

  test "rejects an unsupported locale and leaves the language alone", %{
    thread: thread,
    ctx: ctx
  } do
    assert {:error, message} = SetLanguage.answer(%{"locale" => "ja"}, ctx)
    assert message =~ "zh-TW or en"
    assert Repo.reload!(thread).locale == "zh-TW"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/assistant/tasks/ask_teacher_test.exs test/ganesha/assistant/tasks/set_language_test.exs`
Expected: FAIL — `UndefinedFunctionError: function Ganesha.Assistant.Tasks.AskTeacher.answer/2 is undefined (module Ganesha.Assistant.Tasks.AskTeacher is not available)` (same for `SetLanguage`).

- [ ] **Step 3: Write the behaviour, the struct and the two control tools**

`lib/ganesha/assistant/task.ex`:

```elixir
defmodule Ganesha.Assistant.Task do
  @moduledoc """
  The behaviour every LINE assistant task and control tool implements
  (docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md §4.2).

  `:change` tasks implement `propose/2`, `apply/2` and `describe/2`;
  `:lookup` and `:control` tasks implement `answer/2`.

  - `propose/2` never writes. It resolves ids, checks the request against
    current data, and captures "before" values into `parsed`. Its
    `{:error, text}` goes back to the model as the tool result.
  - `apply/2` runs inside the transaction opened by
    `Ganesha.Assistant.confirm_draft/2` and only calls domain functions. It
    must not trust `parsed` beyond the keys its own `propose/2` wrote.
  - `describe/2` reads only `parsed`; it never queries current data.

  Never `alias` this module as `Task`: it would shadow Elixir's `Task`.
  """

  @type ctx :: %{thread: Ganesha.Assistant.Thread.t(), locale: String.t(), today: Date.t()}
  @type card :: {atom(), term()}

  @callback name() :: String.t()
  @callback kind() :: :lookup | :change | :control
  # description and input_schema only; the registry adds name and the shared fields
  @callback tool() :: %{description: String.t(), input_schema: map()}

  # :change tasks
  @callback propose(input :: map(), ctx()) ::
              {:ok, %{student_id: integer() | nil, parsed: map()}} | {:error, String.t()}
  @callback apply(parsed :: map(), confirmed_by :: String.t()) ::
              {:ok, {record_type :: String.t() | nil, record_id :: integer() | nil}}
              | {:error, term()}
  @callback describe(parsed :: map(), locale :: String.t()) :: %{
              title: String.t(),
              lines: [String.t()],
              changes: [
                {label :: String.t(), before :: String.t() | nil, after_value :: String.t()}
              ],
              web_path: String.t() | nil
            }

  # :lookup and :control tasks
  @callback answer(input :: map(), ctx()) ::
              {:ok,
               %{
                 required(:data) => String.t(),
                 optional(:card) => card(),
                 optional(:choices) => [String.t()]
               }}
              | {:error, String.t()}

  @optional_callbacks propose: 2, apply: 2, describe: 2, answer: 2
end
```

`lib/ganesha/assistant/turn.ex`:

```elixir
defmodule Ganesha.Assistant.Turn do
  @moduledoc """
  What one agent turn produced (spec §4.2): the model's final text, the
  Drafts it created, the lookup cards it chose to show, and the quick-reply
  choices from `ask_teacher`.
  """

  @type t :: %__MODULE__{
          text: String.t() | nil,
          draft_ids: [integer()],
          cards: [Ganesha.Assistant.Task.card()],
          choices: [String.t()]
        }

  defstruct text: nil, draft_ids: [], cards: [], choices: []
end
```

`lib/ganesha/assistant/tasks/ask_teacher.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.AskTeacher do
  @moduledoc """
  Control tool `ask_teacher` (spec §2 rule 5, §3.2): when the model cannot
  decide, it asks with 2–13 options of at most 20 characters. The options
  become quick-reply buttons whose text comes back as her next message.
  """
  @behaviour Ganesha.Assistant.Task

  @max_label 20

  @impl true
  def name, do: "ask_teacher"

  @impl true
  def kind, do: :control

  @impl true
  def tool do
    %{
      description: """
      Ask the teacher to choose when you cannot decide on your own, for example two \
      students named Amy or two Tuesday classes. Each option becomes a button; her tap \
      comes back as her next message. After calling this, end your turn with the question \
      itself as your reply.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          question: %{type: "string"},
          options: %{
            type: "array",
            items: %{type: "string", maxLength: @max_label},
            minItems: 2,
            maxItems: 13
          }
        },
        required: ["question", "options"]
      }
    }
  end

  @impl true
  def answer(%{"question" => question, "options" => options}, _ctx)
      when is_binary(question) and is_list(options) do
    if String.trim(question) != "" and valid_options?(options) do
      {:ok,
       %{
         data:
           "Buttons shown to the teacher: #{Enum.join(options, " / ")}. " <>
             "End your turn now with the question as your reply.",
         choices: options
       }}
    else
      {:error, invalid()}
    end
  end

  def answer(_input, _ctx), do: {:error, invalid()}

  defp valid_options?(options) do
    length(options) in 2..13 and
      Enum.all?(options, &(is_binary(&1) and &1 != "" and String.length(&1) <= @max_label))
  end

  defp invalid, do: "ask_teacher needs a question and 2–13 options of 1–20 characters each"
end
```

`lib/ganesha/assistant/tasks/set_language.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.SetLanguage do
  @moduledoc """
  Control tool `set_language` (spec §3.2, §6.5): switches the chat's language
  at once. Not a ledger change, so no Draft (spec §2 rule 1).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Assistant

  @impl true
  def name, do: "set_language"

  @impl true
  def kind, do: :control

  @impl true
  def tool do
    %{
      description: """
      Switch this chat's reply language when the person asks for it. zh-TW is \
      Traditional Chinese, en is English.\
      """,
      input_schema: %{
        type: "object",
        properties: %{locale: %{type: "string", enum: ["zh-TW", "en"]}},
        required: ["locale"]
      }
    }
  end

  @impl true
  def answer(%{"locale" => locale}, %{thread: thread}) do
    case Assistant.set_locale(thread, locale) do
      {:ok, _thread} -> {:ok, %{data: confirmation(locale)}}
      {:error, _reason} -> {:error, "unsupported locale #{inspect(locale)}; use zh-TW or en"}
    end
  end

  def answer(_input, _ctx), do: {:error, "set_language needs a locale: zh-TW or en"}

  defp confirmation("en"), do: "Language switched to English."
  defp confirmation(_locale), do: "已切換為繁體中文。"
end
```

In `lib/ganesha/assistant/thread.ex`, add the type right after the `schema "assistant_threads" do … end` block:

```elixir
  @type t :: %__MODULE__{}
```

- [ ] **Step 4: Run the tests and the compiler**

Run: `mix test test/ganesha/assistant/tasks/ask_teacher_test.exs test/ganesha/assistant/tasks/set_language_test.exs && mix compile --warnings-as-errors`
Expected: PASS (7 tests, 0 failures); compile clean.

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/task.ex lib/ganesha/assistant/turn.ex lib/ganesha/assistant/tasks/ask_teacher.ex lib/ganesha/assistant/tasks/set_language.ex lib/ganesha/assistant/thread.ex test/ganesha/assistant/tasks/ask_teacher_test.exs test/ganesha/assistant/tasks/set_language_test.exs
git commit -m "Add the assistant Task behaviour, Turn, and the ask_teacher and set_language control tools"
```

---

### Task 2: `record_payment` task

**Files:**
- Create: `lib/ganesha/assistant/tasks/record_payment.ex`
- Modify: `lib/ganesha/people.ex` (add `get_student/1`)
- Modify: `lib/ganesha/assistant.ex` (add `format_changeset_errors/1`)
- Test: `test/ganesha/assistant/tasks/record_payment_test.exs`

**Interfaces:**
- Consumes: `Sales.list_purchases_for_student/1` (preloads `:package`, `:slot`), `Sales.list_payments_for_purchase/1`, `Sales.payable/1`, `Sales.record_payment/1`, `Sales.confirm_payment/2`, `Payment.changeset/2`, `Payment.methods/0`, `GaneshaWeb.Fmt.amount/1`, `Fmt.method/1`, `Fmt.date/1`, `Clock.today/0`.
- Produces:
  - `Ganesha.People.get_student(id :: integer()) :: Student.t() | nil`.
  - `Ganesha.Assistant.format_changeset_errors(Ecto.Changeset.t()) :: String.t()` — `"field: message; field: message"` with `%{…}` interpolated.
  - `Ganesha.Assistant.Tasks.RecordPayment` — `name() == "record_payment"`, `kind() == :change`; `propose(input, ctx)` → `parsed` keys `"purchase_id" "amount" "method" "paid_on" (ISO) "reported_last5" "note"` (applied) plus display keys `"student_id" "student_name" "package_name" "before_owed"`; `apply(parsed, confirmed_by) :: {:ok, {"Ganesha.Sales.Payment", id}} | {:error, :missing_purchase_id | Ecto.Changeset.t()}`; `describe(parsed, locale)` title `"收款 <name> NT$<amount>"` / `"Payment <name> NT$<amount>"`, change `{"尚欠" | "Owed", before_owed, before_owed - amount}`, `web_path "/students/<id>"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha/assistant/tasks/record_payment_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.RecordPaymentTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Tasks.RecordPayment
  alias Ganesha.Sales.Payment

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, package} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 1600})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      package: package,
      purchase: purchase
    }
  end

  defp input(student, extra \\ %{}) do
    Map.merge(%{"student_id" => student.id, "amount" => 1600, "method" => "line_pay"}, extra)
  end

  describe "propose/2" do
    test "resolves the one purchase she owes on and captures what was owed before", c do
      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               RecordPayment.propose(input(c.student), c.ctx)

      assert student_id == c.student.id
      assert parsed["purchase_id"] == c.purchase.id
      assert parsed["amount"] == 1600
      assert parsed["paid_on"] == "2026-10-02"
      assert parsed["before_owed"] == 1600
      assert parsed["student_name"] == "Lulu"
      assert parsed["package_name"] == "月課程"
      assert Repo.aggregate(Payment, :count) == 0
    end

    test "asks for purchase_id when she owes on several purchases", c do
      {:ok, _} =
        Sales.create_purchase(%{
          student_id: c.student.id,
          package_id: c.package.id,
          list_price: 400
        })

      assert {:error, message} = RecordPayment.propose(input(c.student), c.ctx)
      assert message =~ "several purchases"
      assert message =~ "purchase #{c.purchase.id}"
    end

    test "takes an explicit purchase_id only if it is hers", c do
      {:ok, amy} = People.create_student(%{display_name: "Amy"})

      {:ok, amys} =
        Sales.create_purchase(%{student_id: amy.id, package_id: c.package.id, list_price: 400})

      assert {:error, message} =
               RecordPayment.propose(input(c.student, %{"purchase_id" => amys.id}), c.ctx)

      assert message =~ "not one of Lulu's purchases"
    end

    test "rejects an unknown student", c do
      assert {:error, message} =
               RecordPayment.propose(
                 %{"student_id" => -1, "amount" => 1, "method" => "cash"},
                 c.ctx
               )

      assert message =~ "no student with id -1"
    end

    test "rejects what the payment rules reject", c do
      assert {:error, message} =
               RecordPayment.propose(input(c.student, %{"method" => "bitcoin"}), c.ctx)

      assert message =~ "method: is invalid"

      assert {:error, message} =
               RecordPayment.propose(input(c.student, %{"reported_last5" => "abc"}), c.ctx)

      assert message =~ "reported_last5: must be up to five digits"
    end
  end

  describe "apply/2" do
    test "records the payment and confirms it as the teacher", c do
      {:ok, %{parsed: parsed}} = RecordPayment.propose(input(c.student), c.ctx)

      assert {:ok, {"Ganesha.Sales.Payment", id}} = RecordPayment.apply(parsed, "line:teacher")

      payment = Repo.get!(Payment, id)
      assert payment.state == "confirmed"
      assert payment.confirmed_by == "line:teacher"
      assert payment.source == "line_draft"
      assert payment.amount == 1600
      assert payment.paid_on == ~D[2026-10-02]
    end

    test "uses only the keys propose/2 wrote", c do
      {:ok, %{parsed: parsed}} = RecordPayment.propose(input(c.student), c.ctx)
      tampered = Map.merge(parsed, %{"source" => "manual", "state" => "disputed"})

      assert {:ok, {_type, id}} = RecordPayment.apply(tampered, "line:teacher")

      payment = Repo.get!(Payment, id)
      assert payment.source == "line_draft"
      assert payment.state == "confirmed"
    end

    test "fails without a purchase instead of guessing" do
      assert {:error, :missing_purchase_id} =
               RecordPayment.apply(%{"amount" => 400, "method" => "cash"}, "line:teacher")

      assert Repo.aggregate(Payment, :count) == 0
    end

    test "returns the changeset when the payment rules reject it", c do
      assert {:error, %Ecto.Changeset{}} =
               RecordPayment.apply(
                 %{"purchase_id" => c.purchase.id, "amount" => -5, "method" => "cash"},
                 "line:teacher"
               )
    end
  end

  describe "describe/2" do
    @parsed %{
      "student_id" => 7,
      "student_name" => "Lulu",
      "purchase_id" => 3,
      "amount" => 1600,
      "method" => "line_pay",
      "paid_on" => "2026-10-02",
      "reported_last5" => "12345",
      "package_name" => "月課程",
      "before_owed" => 1600
    }

    test "is built from parsed only and shows what is owed before → after" do
      assert %{
               title: "收款 Lulu NT$1,600",
               lines: ["方案：月課程", "付款方式：Line Pay", "付款日：10月2日", "末五碼：12345"],
               changes: [{"尚欠", "NT$1,600", "NT$0"}],
               web_path: "/students/7"
             } = RecordPayment.describe(@parsed, "zh-TW")
    end

    test "speaks English when the chat does" do
      assert %{
               title: "Payment Lulu NT$1,600",
               lines: [
                 "Package: 月課程",
                 "Method: LINE Pay",
                 "Paid on: 2026-10-02",
                 "Last 5 digits: 12345"
               ],
               changes: [{"Owed", "NT$1,600", "NT$0"}]
             } = RecordPayment.describe(@parsed, "en")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/ganesha/assistant/tasks/record_payment_test.exs`
Expected: FAIL — `module Ganesha.Assistant.Tasks.RecordPayment is not available`.

- [ ] **Step 3: Add the two helpers**

In `lib/ganesha/people.ex`, after `get_student!/1`:

```elixir
  def get_student(id), do: Repo.get(Student, id)
```

In `lib/ganesha/assistant.ex`, add this public function just before the final `end` of the module:

```elixir
  @doc "A changeset's errors as `field: message`, joined with `; ` (spec §7)."
  def format_changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> Enum.join("; ")
  end
```

- [ ] **Step 4: Write the task**

`lib/ganesha/assistant/tasks/record_payment.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.RecordPayment do
  @moduledoc """
  `record_payment` (spec §3.1 #14): a payment recorded and confirmed
  together when the teacher confirms the Draft. In the Teacher chat and the
  Group chat, where "2.Lulu（Line pay 1200元）" becomes one of these.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Clock, People, Sales}
  alias Ganesha.Sales.Payment
  alias GaneshaWeb.Fmt

  # What `propose/2` writes for `apply/2`; every other key in `parsed` is display.
  @apply_keys ~w(purchase_id amount method paid_on reported_last5 note)

  @impl true
  def name, do: "record_payment"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Record money a student paid. This only proposes a Draft; the payment is recorded \
      and confirmed when the teacher taps Confirm. Use ids from the studio snapshot. Omit \
      purchase_id when the student owes on exactly one purchase.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          purchase_id: %{type: "integer", description: "The purchase this money pays for"},
          amount: %{type: "integer", description: "NT$, whole dollars"},
          method: %{type: "string", enum: Payment.methods()},
          paid_on: %{type: "string", description: "ISO 8601 date; defaults to today"},
          reported_last5: %{
            type: "string",
            description: "Last five digits of the sender's account, if given"
          },
          note: %{type: "string"}
        },
        required: ["student_id", "amount", "method"]
      }
    }
  end

  @impl true
  def propose(input, ctx) do
    with {:ok, student} <- fetch_student(input["student_id"]),
         {:ok, purchase, owed} <- pick_purchase(student, input["purchase_id"]),
         {:ok, paid_on} <- parse_date(input["paid_on"], ctx.today),
         {:ok, payment} <-
           validate_payment(%{
             "purchase_id" => purchase.id,
             "amount" => input["amount"],
             "method" => input["method"],
             "paid_on" => paid_on,
             "reported_last5" => input["reported_last5"],
             "note" => input["note"]
           }) do
      parsed = %{
        "purchase_id" => payment.purchase_id,
        "amount" => payment.amount,
        "method" => payment.method,
        "paid_on" => Date.to_iso8601(payment.paid_on),
        "reported_last5" => payment.reported_last5,
        "note" => payment.note,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "package_name" => purchase.package.name,
        "before_owed" => owed
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, confirmed_by) do
    today = Date.to_iso8601(Clock.today())

    # Drafts migrated from the old `payment` kind may lack `paid_on`.
    attrs =
      parsed
      |> Map.take(@apply_keys)
      |> Map.update("paid_on", today, &(&1 || today))
      |> Map.put("source", "line_draft")

    with :ok <- require_purchase(attrs),
         {:ok, payment} <- Sales.record_payment(attrs),
         {:ok, payment} <- Sales.confirm_payment(payment, confirmed_by) do
      {:ok, {"Ganesha.Sales.Payment", payment.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    amount = parsed["amount"]

    %{
      title: "#{label(:title, locale)} #{parsed["student_name"] || "?"} #{money(amount)}",
      lines:
        Enum.reject(
          [
            line(:package, parsed["package_name"], locale),
            line(:method, method_name(parsed["method"], locale), locale),
            line(:paid_on, date_text(parsed["paid_on"], locale), locale),
            line(:last5, parsed["reported_last5"], locale),
            line(:note, parsed["note"], locale)
          ],
          &is_nil/1
        ),
      changes: owed_change(parsed["before_owed"], amount, locale),
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

  defp fetch_student(id) when is_integer(id) do
    case People.get_student(id) do
      nil -> {:error, "no student with id #{id}; use a student id from the snapshot"}
      student -> {:ok, student}
    end
  end

  defp fetch_student(_id), do: {:error, "student_id must be a student id from the snapshot"}

  defp pick_purchase(student, purchase_id) do
    owing =
      student.id
      |> Sales.list_purchases_for_student()
      |> Enum.map(&{&1, owed(&1)})

    pick(owing, purchase_id, student)
  end

  defp pick(owing, nil, student) do
    case Enum.filter(owing, fn {_purchase, owed} -> owed > 0 end) do
      [{purchase, owed}] ->
        {:ok, purchase, owed}

      [] ->
        {:error,
         "#{student.display_name} owes nothing on any purchase; " <>
           "ask the teacher which purchase this money is for"}

      several ->
        {:error,
         "#{student.display_name} owes on several purchases: " <>
           Enum.map_join(several, "; ", &purchase_text/1) <>
           ". Pass purchase_id, or ask the teacher which one."}
    end
  end

  defp pick(owing, purchase_id, student) when is_integer(purchase_id) do
    case Enum.find(owing, fn {purchase, _owed} -> purchase.id == purchase_id end) do
      {purchase, owed} -> {:ok, purchase, owed}
      nil -> {:error, "purchase #{purchase_id} is not one of #{student.display_name}'s purchases"}
    end
  end

  defp pick(_owing, _purchase_id, _student), do: {:error, "purchase_id must be an integer"}

  defp owed(purchase) do
    paid =
      purchase.id
      |> Sales.list_payments_for_purchase()
      |> Enum.filter(&(&1.state == "confirmed"))
      |> Enum.map(& &1.amount)
      |> Enum.sum()

    Sales.payable(purchase) - paid
  end

  defp purchase_text({purchase, owed}) do
    slot = if purchase.slot, do: " #{purchase.slot.label}", else: ""
    "purchase #{purchase.id} #{purchase.package.name}#{slot} (owes #{money(owed)})"
  end

  defp parse_date(nil, today), do: {:ok, today}

  defp parse_date(text, _today) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "paid_on must be an ISO 8601 date like 2026-10-02"}
    end
  end

  defp parse_date(_value, _today),
    do: {:error, "paid_on must be an ISO 8601 date like 2026-10-02"}

  defp validate_payment(attrs) do
    case %Payment{} |> Payment.changeset(attrs) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, changeset} ->
        {:error, "invalid payment: " <> Assistant.format_changeset_errors(changeset)}
    end
  end

  defp require_purchase(%{"purchase_id" => id}) when is_integer(id), do: :ok
  defp require_purchase(_attrs), do: {:error, :missing_purchase_id}

  defp label(:title, "en"), do: "Payment"
  defp label(:title, _), do: "收款"
  defp label(:package, "en"), do: "Package"
  defp label(:package, _), do: "方案"
  defp label(:method, "en"), do: "Method"
  defp label(:method, _), do: "付款方式"
  defp label(:paid_on, "en"), do: "Paid on"
  defp label(:paid_on, _), do: "付款日"
  defp label(:last5, "en"), do: "Last 5 digits"
  defp label(:last5, _), do: "末五碼"
  defp label(:note, "en"), do: "Note"
  defp label(:note, _), do: "備註"
  defp label(:owed, "en"), do: "Owed"
  defp label(:owed, _), do: "尚欠"

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

  defp owed_change(before, amount, locale) when is_integer(before) and is_integer(amount),
    do: [{label(:owed, locale), money(before), money(before - amount)}]

  defp owed_change(_before, _amount, _locale), do: []

  defp money(n) when is_integer(n), do: "NT$" <> Fmt.amount(n)
  defp money(other), do: to_string(other)
end
```

- [ ] **Step 5: Run the test and the compiler**

Run: `mix test test/ganesha/assistant/tasks/record_payment_test.exs && mix compile --warnings-as-errors`
Expected: PASS (11 tests, 0 failures); compile clean.

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/tasks/record_payment.ex lib/ganesha/people.ex lib/ganesha/assistant.ex test/ganesha/assistant/tasks/record_payment_test.exs
git commit -m "Add the record_payment assistant task"
```

---

### Task 3: `book_one_off` task

**Files:**
- Create: `lib/ganesha/assistant/tasks/book_one_off.ex`
- Modify: `lib/ganesha/studio.ex` (add `get_session/1`), `lib/ganesha/catalog.ex` (add `get_package/1`)
- Test: `test/ganesha/assistant/tasks/book_one_off_test.exs`

**Interfaces:**
- Consumes: `People.get_student/1` (Task 2), `Enrolling.add_one_off(session, student, package, custom_amount:, note:) :: {:ok, %{purchase:, attendance:}} | {:error, changeset}`, `Roster.list_for_session/1`, `Catalog.package_available?/2`, `Catalog.price_for/2`, `Sales.purchased_package_ids_for_student/1`, `Fmt.session_label/1`, `Fmt.session_time_range/1`, `Fmt.short_date/1`, `Fmt.weekday/1`, `Fmt.amount/1`.
- Produces:
  - `Ganesha.Studio.get_session(id) :: Session.t() | nil` (slot preloaded); `Ganesha.Catalog.get_package(id) :: Package.t() | nil`.
  - `Ganesha.Assistant.Tasks.BookOneOff` — `name() == "book_one_off"`, `kind() == :change`; `parsed` applied keys `"student_id" "session_id" "package_id" "custom_amount" "note"`, display keys `"student_name" "package_name" "package_kind" "price" "session_date" "session_label" "session_time" "before_count"`; `apply/2 :: {:ok, {"Ganesha.Sales.Purchase", id}} | {:error, :not_found | :session_cancelled | Ecto.Changeset.t()}`; `describe/2` title `"單堂|體驗 <name> <M/D>"` / `"Drop-in|Trial <name> <M/D>"`, changes `[{"名單", "n 人", "n+1 人"}, {"應付", nil, "NT$x"}]` (en `{"Roster", "n", "n+1"}`, `{"Owed", nil, …}`), `web_path "/sessions/<id>"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha/assistant/tasks/book_one_off_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.BookOneOffTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Tasks.BookOneOff

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
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

    {:ok, drop_in} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, trial} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 300})

    {:ok, monthly} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 350})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      session: session,
      drop_in: drop_in,
      trial: trial,
      monthly: monthly
    }
  end

  defp input(student, session, package) do
    %{"student_id" => student.id, "session_id" => session.id, "package_id" => package.id}
  end

  describe "propose/2" do
    test "resolves the ids and captures the roster before the booking", c do
      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)

      assert student_id == c.student.id
      assert parsed["before_count"] == 0
      assert parsed["price"] == 400
      assert parsed["session_date"] == "2026-10-07"
      assert parsed["session_label"] == "基礎"
      assert parsed["session_time"] == "19:00–20:15"
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "rejects a monthly package", c do
      assert {:error, message} = BookOneOff.propose(input(c.student, c.session, c.monthly), c.ctx)
      assert message =~ "drop_in or trial"
    end

    test "rejects a cancelled session", c do
      {:ok, _} = Studio.cancel_session(c.session, "颱風")
      assert {:error, message} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      assert message =~ "cancelled"
    end

    test "rejects a student who is already in the session", c do
      {:ok, _} = Enrolling.add_one_off(c.session, c.student, c.drop_in, [])
      assert {:error, message} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      assert message =~ "already booked"
    end

    test "rejects an unknown session", c do
      bad = %{"student_id" => c.student.id, "session_id" => -1, "package_id" => c.drop_in.id}
      assert {:error, message} = BookOneOff.propose(bad, c.ctx)
      assert message =~ "no session with id -1"
    end
  end

  describe "apply/2" do
    test "creates the purchase and seats the student", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)

      assert {:ok, {"Ganesha.Sales.Purchase", purchase_id}} =
               BookOneOff.apply(parsed, "line:teacher")

      assert [%{student_id: student_id, kind: "drop_in", purchase_id: ^purchase_id}] =
               Roster.list_for_session(c.session)

      assert student_id == c.student.id
      assert Sales.get_purchase!(purchase_id).list_price == 400
    end

    test "a trial package seats a trial", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.trial), c.ctx)
      assert {:ok, _} = BookOneOff.apply(parsed, "line:teacher")
      assert [%{kind: "trial"}] = Roster.list_for_session(c.session)
    end

    test "fails if the session was cancelled after the Draft was made", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      {:ok, _} = Studio.cancel_session(c.session, "颱風")

      assert {:error, :session_cancelled} = BookOneOff.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "returns the changeset when the student was booked in the meantime", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      {:ok, _} = Enrolling.add_one_off(c.session, c.student, c.drop_in, [])

      assert {:error, %Ecto.Changeset{}} = BookOneOff.apply(parsed, "line:teacher")
      assert length(Sales.list_purchases_for_student(c.student.id)) == 1
    end
  end

  describe "describe/2" do
    test "shows the session and the roster before → after", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)

      assert %{
               title: "單堂 Lulu 10/7",
               lines: ["課堂：10/7 週三 基礎 19:00–20:15", "方案：單堂 NT$400"],
               changes: [{"名單", "0 人", "1 人"}, {"應付", nil, "NT$400"}],
               web_path: web_path
             } = BookOneOff.describe(parsed, "zh-TW")

      assert web_path == "/sessions/#{c.session.id}"
    end

    test "speaks English when the chat does", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.trial), c.ctx)

      assert %{
               title: "Trial Lulu 10/7",
               lines: ["Session: Wed 10/7 基礎 19:00–20:15", "Package: 體驗 NT$300"],
               changes: [{"Roster", "0", "1"}, {"Owed", nil, "NT$300"}]
             } = BookOneOff.describe(parsed, "en")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/ganesha/assistant/tasks/book_one_off_test.exs`
Expected: FAIL — `module Ganesha.Assistant.Tasks.BookOneOff is not available`.

- [ ] **Step 3: Add the two getters**

In `lib/ganesha/studio.ex`, after `get_session!/1`:

```elixir
  def get_session(id), do: Session |> Repo.get(id) |> Repo.preload(:slot)
```

In `lib/ganesha/catalog.ex`, after `get_package!/1`:

```elixir
  def get_package(id), do: Repo.get(Package, id)
```

- [ ] **Step 4: Write the task**

`lib/ganesha/assistant/tasks/book_one_off.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.BookOneOff do
  @moduledoc """
  `book_one_off` (spec §3.1 #13): a 單堂 or 體驗 in one Session through
  `Ganesha.Enrolling.add_one_off/4`, so the booking always has a purchase
  behind it (ADR 0001 — it replaces the old raw attendance Draft).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}
  alias GaneshaWeb.Fmt

  @apply_keys ~w(student_id session_id package_id custom_amount note)
  @one_off_kinds ~w(drop_in trial)

  @impl true
  def name, do: "book_one_off"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Book a student into one Session as a single class (單堂) or a trial (體驗). This only \
      proposes a Draft; the purchase and the booking are created when the teacher taps \
      Confirm. Use ids from the studio snapshot; package_id must be a drop_in or trial \
      package.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          session_id: %{type: "integer"},
          package_id: %{type: "integer"},
          custom_amount: %{
            type: "integer",
            description: "NT$ owed instead of the package price, only if the teacher says so"
          },
          note: %{type: "string"}
        },
        required: ["student_id", "session_id", "package_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, student} <- fetch(:student, input["student_id"]),
         {:ok, session} <- fetch(:session, input["session_id"]),
         {:ok, package} <- fetch(:package, input["package_id"]),
         :ok <- check_scheduled(session),
         :ok <- check_one_off(package),
         :ok <- check_available(package, student),
         :ok <- check_amount(input["custom_amount"]),
         roster = Roster.list_for_session(session),
         :ok <- check_not_booked(roster, student) do
      parsed = %{
        "student_id" => student.id,
        "session_id" => session.id,
        "package_id" => package.id,
        "custom_amount" => input["custom_amount"],
        "note" => input["note"],
        "student_name" => student.display_name,
        "package_name" => package.name,
        "package_kind" => package.kind,
        "price" => Catalog.price_for(package, 1),
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
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
         {:ok, package} <- load(:package, attrs["package_id"]),
         :ok <- still_scheduled(session),
         {:ok, %{purchase: purchase}} <-
           Enrolling.add_one_off(session, student, package,
             custom_amount: attrs["custom_amount"],
             note: attrs["note"]
           ) do
      {:ok, {"Ganesha.Sales.Purchase", purchase.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title:
        "#{kind_name(parsed["package_kind"], locale)} #{parsed["student_name"]} #{short_date(date)}",
      lines:
        Enum.reject(
          [
            session_line(parsed, date, locale),
            package_line(parsed, locale),
            note_line(parsed["note"], locale)
          ],
          &is_nil/1
        ),
      changes:
        roster_change(parsed["before_count"], locale) ++
          [{owed_label(locale), nil, money(parsed["custom_amount"] || parsed["price"])}],
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
  defp get(:package, id), do: Catalog.get_package(id)

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_one_off(%{kind: kind}) when kind in @one_off_kinds, do: :ok

  defp check_one_off(package),
    do: {:error, "#{package.name} is not a 單堂 or 體驗 package; use a drop_in or trial package_id"}

  defp check_available(package, student) do
    if Catalog.package_available?(package, Sales.purchased_package_ids_for_student(student.id)),
      do: :ok,
      else: {:error, "#{package.name} is closed to #{student.display_name}"}
  end

  defp check_amount(nil), do: :ok
  defp check_amount(amount) when is_integer(amount) and amount >= 0, do: :ok

  defp check_amount(_amount),
    do: {:error, "custom_amount must be a whole NT$ amount of 0 or more"}

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

  defp kind_name("trial", "en"), do: "Trial"
  defp kind_name(_kind, "en"), do: "Drop-in"
  defp kind_name("trial", _locale), do: "體驗"
  defp kind_name(_kind, _locale), do: "單堂"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, _locale),
    do:
      "課堂：#{Fmt.short_date(date)} #{Fmt.weekday(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp package_line(parsed, "en"),
    do: "Package: #{parsed["package_name"]} #{money(parsed["price"])}"

  defp package_line(parsed, _locale), do: "方案：#{parsed["package_name"]} #{money(parsed["price"])}"

  defp note_line(note, _locale) when note in [nil, ""], do: nil
  defp note_line(note, "en"), do: "Note: #{note}"
  defp note_line(note, _locale), do: "備註：#{note}"

  defp roster_change(count, "en") when is_integer(count),
    do: [{"Roster", "#{count}", "#{count + 1}"}]

  defp roster_change(count, _locale) when is_integer(count),
    do: [{"名單", "#{count} 人", "#{count + 1} 人"}]

  defp roster_change(_count, _locale), do: []

  defp owed_label("en"), do: "Owed"
  defp owed_label(_locale), do: "應付"

  defp money(n) when is_integer(n), do: "NT$" <> Fmt.amount(n)
  defp money(other), do: to_string(other)
end
```

- [ ] **Step 5: Run the test and the compiler**

Run: `mix test test/ganesha/assistant/tasks/book_one_off_test.exs && mix compile --warnings-as-errors`
Expected: PASS (11 tests, 0 failures); compile clean.

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/tasks/book_one_off.ex lib/ganesha/studio.ex lib/ganesha/catalog.ex test/ganesha/assistant/tasks/book_one_off_test.exs
git commit -m "Add the book_one_off assistant task"
```

---

### Task 4: `makeup_request` task

**Files:**
- Create: `lib/ganesha/assistant/tasks/makeup_request.ex`
- Test: `test/ganesha/assistant/tasks/makeup_request_test.exs`

**Interfaces:**
- Consumes: `People.get_student/1` (Task 2).
- Produces: `Ganesha.Assistant.Tasks.MakeupRequest` — `name() == "makeup_request"`, `kind() == :change`; `propose/2` requires a non-blank `"note"`, optional `"student_id"`; `parsed` = `%{"note", "student_id", "student_name"}`; `apply/2` always `{:ok, {nil, nil}}` (acknowledged only); `describe/2` title `"補課需求 <name>"` / `"Makeup request <name>"` (name omitted when unknown), `lines: [note]`, `changes: []`, `web_path "/students/<id>"` or `nil`. Error text for a blank note: `"makeup_request needs a note saying what the student asked for"`.

- [ ] **Step 1: Write the failing test**

`test/ganesha/assistant/tasks/makeup_request_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.MakeupRequestTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.Tasks.MakeupRequest

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "records what the student asked for and who asked", %{ctx: ctx} do
    {:ok, student} = People.create_student(%{display_name: "蘭子"})

    assert {:ok, %{student_id: student_id, parsed: parsed}} =
             MakeupRequest.propose(
               %{"student_id" => student.id, "note" => " 想補 8/17 或 8/31 "},
               ctx
             )

    assert student_id == student.id

    assert parsed == %{
             "note" => "想補 8/17 或 8/31",
             "student_id" => student.id,
             "student_name" => "蘭子"
           }
  end

  test "can be made without knowing the student", %{ctx: ctx} do
    assert {:ok, %{student_id: nil, parsed: %{"student_id" => nil}}} =
             MakeupRequest.propose(%{"note" => "有人想補課"}, ctx)
  end

  test "rejects an unknown student and a blank note", %{ctx: ctx} do
    assert {:error, message} = MakeupRequest.propose(%{"student_id" => -1, "note" => "x"}, ctx)
    assert message =~ "no student with id -1"

    assert {:error, "makeup_request needs a note saying what the student asked for"} =
             MakeupRequest.propose(%{"note" => "  "}, ctx)
  end

  test "confirming only acknowledges it" do
    assert {:ok, {nil, nil}} = MakeupRequest.apply(%{"note" => "8/17"}, "line:teacher")
  end

  test "describes the request from parsed only" do
    parsed = %{"note" => "想補 8/17", "student_id" => 4, "student_name" => "蘭子"}

    assert %{title: "補課需求 蘭子", lines: ["想補 8/17"], changes: [], web_path: "/students/4"} =
             MakeupRequest.describe(parsed, "zh-TW")

    assert %{title: "Makeup request", web_path: nil} =
             MakeupRequest.describe(%{"note" => "8/17"}, "en")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/ganesha/assistant/tasks/makeup_request_test.exs`
Expected: FAIL — `module Ganesha.Assistant.Tasks.MakeupRequest is not available`.

- [ ] **Step 3: Write the task**

`lib/ganesha/assistant/tasks/makeup_request.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.MakeupRequest do
  @moduledoc """
  `makeup_request` (spec §3.1 #21): a student asked for a makeup. The Draft
  is acknowledged only — confirming marks it applied and books nothing; the
  teacher books the makeup herself.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.People

  @impl true
  def name, do: "makeup_request"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Note that a student asked for a makeup class so the teacher can arrange it. \
      Confirming only acknowledges it; nothing is booked. Leave student_id out if you \
      cannot tell who it is.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          note: %{type: "string", description: "What the student asked for, e.g. 想補 8/17 或 8/31"}
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, note} <- fetch_note(input["note"]),
         {:ok, student} <- fetch_student(input["student_id"]) do
      student_id = student && student.id

      {:ok,
       %{
         student_id: student_id,
         parsed: %{
           "note" => note,
           "student_id" => student_id,
           "student_name" => student && student.display_name
         }
       }}
    end
  end

  @impl true
  def apply(_parsed, _confirmed_by), do: {:ok, {nil, nil}}

  @impl true
  def describe(parsed, locale) do
    %{
      title: Enum.join(Enum.reject([title(locale), parsed["student_name"]], &is_nil/1), " "),
      lines: Enum.reject([parsed["note"]], &(&1 in [nil, ""])),
      changes: [],
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

  defp fetch_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> {:error, missing_note()}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_note(_note), do: {:error, missing_note()}

  defp missing_note, do: "makeup_request needs a note saying what the student asked for"

  defp fetch_student(nil), do: {:ok, nil}

  defp fetch_student(id) when is_integer(id) do
    case People.get_student(id) do
      nil ->
        {:error, "no student with id #{id}; use a student id from the snapshot, or leave it out"}

      student ->
        {:ok, student}
    end
  end

  defp fetch_student(_id), do: {:error, "student_id must be an integer id from the snapshot"}

  defp title("en"), do: "Makeup request"
  defp title(_locale), do: "補課需求"
end
```

- [ ] **Step 4: Run the test and the compiler**

Run: `mix test test/ganesha/assistant/tasks/makeup_request_test.exs && mix compile --warnings-as-errors`
Expected: PASS (5 tests, 0 failures); compile clean.

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks/makeup_request.ex test/ganesha/assistant/tasks/makeup_request_test.exs
git commit -m "Add the makeup_request assistant task"
```

---

### Task 5: `Tasks` registry

**Files:**
- Create: `lib/ganesha/assistant/tasks.ex`
- Test: `test/ganesha/assistant/tasks_test.exs`

**Interfaces:**
- Consumes: the five task modules from Tasks 1–4.
- Produces:
  - `Ganesha.Assistant.Tasks.for_chat(:teacher) == [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage]`; `for_chat(:group) == [RecordPayment, BookOneOff, MakeupRequest]`; `for_chat(:student) == [SetLanguage]`.
  - `Ganesha.Assistant.Tasks.fetch(name :: String.t()) :: {:ok, module()} | :error` over every registered task.
  - `Ganesha.Assistant.Tasks.tool_schemas([module()]) :: [%{name: String.t(), description: String.t(), input_schema: map()}]` — atom keys, the shape `Provider.Anthropic` sends; adds optional property `replaces_draft_id` (`%{type: "integer", …}`) to `:change` tasks and `show_card` (`%{type: "boolean", …}`) to `:lookup` tasks; leaves `required` alone.

- [ ] **Step 1: Write the failing test**

`test/ganesha/assistant/tasks_test.exs`:

```elixir
defmodule Ganesha.Assistant.TasksTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Tasks

  alias Ganesha.Assistant.Tasks.{
    AskTeacher,
    BookOneOff,
    MakeupRequest,
    RecordPayment,
    SetLanguage
  }

  defmodule Lookup do
    @behaviour Ganesha.Assistant.Task
    def name, do: "lookup_thing"
    def kind, do: :lookup

    def tool,
      do: %{
        description: "looks up",
        input_schema: %{type: "object", properties: %{q: %{type: "string"}}}
      }

    def answer(_input, _ctx), do: {:ok, %{data: "x"}}
  end

  test "each chat gets its own tasks (spec §2 rule 7)" do
    assert Tasks.for_chat(:group) == [RecordPayment, BookOneOff, MakeupRequest]
    assert Tasks.for_chat(:student) == [SetLanguage]

    assert Enum.sort(Tasks.for_chat(:teacher)) ==
             Enum.sort([RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage])
  end

  test "fetch/1 finds a task by name" do
    assert {:ok, RecordPayment} = Tasks.fetch("record_payment")
    assert {:ok, AskTeacher} = Tasks.fetch("ask_teacher")
    assert :error = Tasks.fetch("payment")
    assert :error = Tasks.fetch(nil)
  end

  test "tool_schemas/1 names each tool and adds the shared fields by kind" do
    [payment, ask, lookup] = Tasks.tool_schemas([RecordPayment, AskTeacher, Lookup])

    assert payment.name == "record_payment"
    assert payment.input_schema.properties.replaces_draft_id.type == "integer"
    assert payment.input_schema.required == ["student_id", "amount", "method"]
    refute Map.has_key?(payment.input_schema.properties, :show_card)

    assert ask.name == "ask_teacher"
    assert ask.input_schema == AskTeacher.tool().input_schema

    assert lookup.name == "lookup_thing"
    assert lookup.description == "looks up"
    assert lookup.input_schema.properties.show_card.type == "boolean"
    refute Map.has_key?(lookup.input_schema.properties, :replaces_draft_id)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/ganesha/assistant/tasks_test.exs`
Expected: FAIL — `function Ganesha.Assistant.Tasks.for_chat/1 is undefined (module Ganesha.Assistant.Tasks is not available)`.

- [ ] **Step 3: Write the registry**

`lib/ganesha/assistant/tasks.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks do
  @moduledoc """
  Which chat gets which tasks (spec §2 rule 7), lookup by name, and the tool
  schemas the model sees (spec §4.2). Schemas use the atom-keyed shape
  `Ganesha.Assistant.Provider.Anthropic` sends: `name`, `description`,
  `input_schema`.
  """

  alias Ganesha.Assistant.Tasks.{
    AskTeacher,
    BookOneOff,
    MakeupRequest,
    RecordPayment,
    SetLanguage
  }

  @teacher [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage]
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

- [ ] **Step 4: Run the test and the compiler**

Run: `mix test test/ganesha/assistant/tasks_test.exs && mix compile --warnings-as-errors`
Expected: PASS (3 tests, 0 failures); compile clean.

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tasks.ex test/ganesha/assistant/tasks_test.exs
git commit -m "Add the assistant Tasks registry"
```

---
### Task 6: Draft lifecycle — migration, schema, `create_draft/3`, `confirm_draft/2`, `discard_draft/1`, `list_pending_drafts/0`

**Files:**
- Create: `priv/repo/migrations/<timestamp>_extend_drafts_for_tasks.exs` (via `mix ecto.gen.migration`)
- Modify: `lib/ganesha/assistant/draft.ex` (rewrite)
- Modify: `lib/ganesha/assistant.ex` (rewrite; `apply_draft/2` removed)
- Modify: `lib/ganesha/assistant/process_event_worker.ex` (`resolve_postback("confirm", …)` only)
- Modify (interim, deleted in Task 7): `lib/ganesha/assistant/tools/propose_payment_draft.ex` (kind), `test/ganesha/assistant/tools/propose_payment_draft_test.exs` (kind assertion)
- Delete: `lib/ganesha/assistant/tools/propose_attendance_draft.ex`, `test/ganesha/assistant/tools/propose_attendance_draft_test.exs` — the `attendance` kind is retired by this task's migration, so its only producer goes now.
- Test: `test/ganesha/assistant_test.exs` (rewrite — the old `describe "apply_draft/2 and discard_draft/1"` block pins the removed `apply_draft/2` and the retired `payment`/`attendance`/`unknown` kinds and is deleted), `test/ganesha/assistant/process_event_worker_test.exs` (four edits), `test/ganesha/assistant/agent_test.exs` (one edit)

**Interfaces:**
- Consumes: `Tasks.fetch/1` (Task 5); `RecordPayment`, `BookOneOff`, `MakeupRequest` `apply/2` and `describe/2` (Tasks 2–4); `Assistant.format_changeset_errors/1` (Task 2).
- Produces:
  - `Draft` fields `failure_reason :string`, `replaced_by_id :integer` (`belongs_to :replaced_by, Draft`), `notified_at :utc_datetime`; `Draft.states() == ~w(pending applied discarded replaced failed)`; `@type t`; `Draft.changeset/2` validates `kind` (must name a `:change` task) only for a new struct; `Draft.apply_changeset/3` unchanged; `Draft.kinds/0` and `Draft.state_changeset/2` removed.
  - `Assistant.create_draft(thread, attrs, opts \\ []) :: {:ok, Draft.t()} | {:error, Ecto.Changeset.t()}` — `opts[:replaces]` = id: same transaction, old Draft set to `"replaced"` with `replaced_by_id` only if same thread and pending.
  - `Assistant.confirm_draft(draft, confirmed_by) :: {:ok, Draft.t()} | {:error, :not_pending} | {:error, {:failed, Draft.t()}}` (exceptions propagate after rollback; the Draft stays pending).
  - `Assistant.discard_draft(draft) :: {:ok, Draft.t()} | {:error, :not_pending}` (compare-and-set; a stale struct is safe).
  - `Assistant.list_pending_drafts() :: [Draft.t()]` — oldest first, `:student` preloaded.
  - `Assistant.describe_draft(draft, locale) :: %{title:, lines:, changes:, web_path:}` — the task's `describe/2`, or `%{title: kind, lines: [], changes: [], web_path: nil}` for a retired kind.
  - `Assistant.get_draft!/1` unchanged.

- [ ] **Step 1: Write the failing tests**

Replace `test/ganesha/assistant_test.exs` with:

```elixir
defmodule Ganesha.AssistantTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Clock, Enrolling, People, Sales, Studio}
  alias Ganesha.Assistant.Draft
  alias Ganesha.Assistant.Tasks.{BookOneOff, RecordPayment}
  alias Ganesha.Sales.Payment

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{thread: thread}
  end

  defp ctx(thread), do: %{thread: thread, locale: "zh-TW", today: Clock.today()}

  defp makeup(thread, note, student_id \\ nil) do
    Assistant.create_draft(thread, %{
      kind: "makeup_request",
      student_id: student_id,
      parsed: %{"note" => note}
    })
  end

  defp payment_draft(thread, overrides \\ %{}) do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 400})

    {:ok, %{student_id: student_id, parsed: parsed}} =
      RecordPayment.propose(
        %{"student_id" => student.id, "amount" => 400, "method" => "cash"},
        ctx(thread)
      )

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "record_payment",
        student_id: student_id,
        parsed: Map.merge(parsed, overrides)
      })

    draft
  end

  defp one_off_draft(thread, overrides \\ %{}) do
    {:ok, student} = People.create_student(%{display_name: "Amy"})

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

    {:ok, package} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 300})

    {:ok, %{student_id: student_id, parsed: parsed}} =
      BookOneOff.propose(
        %{"student_id" => student.id, "session_id" => session.id, "package_id" => package.id},
        ctx(thread)
      )

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "book_one_off",
        student_id: student_id,
        parsed: Map.merge(parsed, overrides)
      })

    %{draft: draft, student: student, session: session, package: package}
  end

  test "get_or_create_thread/2 creates once and reuses on repeat calls" do
    assert {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert {:ok, same} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert thread.id == same.id
  end

  test "get_or_create_thread/2 keeps group and teacher threads separate per source_id" do
    assert {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    assert {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Cabc")
    refute group.id == teacher.id
  end

  test "get_or_create_thread/2 rejects an unknown source_type" do
    assert {:error, changeset} = Assistant.get_or_create_thread("student", "U1")
    assert "is invalid" in errors_on(changeset).source_type
  end

  test "append_message/4 and list_messages/1 round-trip in insertion order", %{thread: thread} do
    {:ok, _} = Assistant.append_message(thread, "user", "誰欠錢？", nil)

    {:ok, _} =
      Assistant.append_message(thread, "assistant", nil, [
        %{id: "t1", name: "record_payment", input: %{}}
      ])

    assert [first, second] = Assistant.list_messages(thread)
    assert first.role == "user"
    assert first.content == "誰欠錢？"
    assert second.role == "assistant"
    assert [%{"id" => "t1", "name" => "record_payment"}] = second.tool_calls
  end

  test "append_message/4 rejects an unknown role", %{thread: thread} do
    assert {:error, changeset} = Assistant.append_message(thread, "system", "x", nil)
    assert "is invalid" in errors_on(changeset).role
  end

  test "get_draft!/1 fetches by id", %{thread: thread} do
    {:ok, draft} = makeup(thread, "8/17")
    assert Assistant.get_draft!(draft.id).id == draft.id
  end

  describe "create_draft/3" do
    test "stamps the thread's latest user message as its origin" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, _} = Assistant.append_message(thread, "user", "蘭子補課8/17or 8/31", nil)

      assert {:ok, draft} = makeup(thread, "8/17 或 8/31")

      [origin] = Assistant.list_messages(thread)
      assert draft.origin_message_id == origin.id
      assert draft.state == "pending"
    end

    test "rejects a kind that names no change task, including retired kinds", %{thread: thread} do
      for kind <- ["bogus", "payment", "attendance", "unknown", "ask_teacher"] do
        assert {:error, changeset} = Assistant.create_draft(thread, %{kind: kind, parsed: %{}})
        assert "is invalid" in errors_on(changeset).kind
      end
    end

    test "validates kind only on insert, so retired kinds stay readable as history", %{
      thread: thread
    } do
      retired =
        Repo.insert!(%Draft{
          thread_id: thread.id,
          kind: "attendance",
          parsed: %{},
          state: "applied"
        })

      assert Draft.changeset(retired, %{confidence: 0.5}).valid?
    end

    test "replaces a pending Draft of the same thread", %{thread: thread} do
      {:ok, old} = makeup(thread, "8/17")

      assert {:ok, new} =
               Assistant.create_draft(
                 thread,
                 %{kind: "makeup_request", parsed: %{"note" => "8/24"}},
                 replaces: old.id
               )

      old = Repo.reload!(old)
      assert old.state == "replaced"
      assert old.replaced_by_id == new.id
      assert new.state == "pending"
    end

    test "leaves another thread's Draft and a settled Draft alone", %{thread: thread} do
      {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, foreign} = makeup(group, "x")
      {:ok, settled} = makeup(thread, "y")
      {:ok, _} = Assistant.discard_draft(settled)

      for old <- [foreign, settled] do
        assert {:ok, _} =
                 Assistant.create_draft(
                   thread,
                   %{kind: "makeup_request", parsed: %{"note" => "z"}},
                   replaces: old.id
                 )
      end

      assert Repo.reload!(foreign).state == "pending"
      assert Repo.reload!(settled).state == "discarded"
    end
  end

  describe "confirm_draft/2" do
    test "applies a record_payment Draft through Sales", %{thread: thread} do
      draft = payment_draft(thread)

      assert {:ok,
              %Draft{state: "applied", applied_record_type: "Ganesha.Sales.Payment"} = applied} =
               Assistant.confirm_draft(draft, "line:teacher")

      payment = Repo.get!(Payment, applied.applied_record_id)
      assert payment.state == "confirmed"
      assert payment.confirmed_by == "line:teacher"
    end

    test "applies exactly once when confirmed twice at the same time", %{thread: thread} do
      draft = payment_draft(thread)

      results =
        [
          Task.async(fn -> Assistant.confirm_draft(draft, "line:teacher") end),
          Task.async(fn -> Assistant.confirm_draft(draft, "line:teacher") end)
        ]
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, %Draft{state: "applied"}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_pending})) == 1
      assert Repo.aggregate(Payment, :count) == 1
    end

    test "marks the Draft failed with an atom reason and writes nothing", %{thread: thread} do
      draft = payment_draft(thread, %{"purchase_id" => nil})

      assert {:error, {:failed, %Draft{state: "failed", failure_reason: "missing_purchase_id"}}} =
               Assistant.confirm_draft(draft, "line:teacher")

      assert Repo.reload!(draft).state == "failed"
      assert Repo.aggregate(Payment, :count) == 0
    end

    test "marks the Draft failed with the changeset's errors and rolls back the whole change", %{
      thread: thread
    } do
      %{draft: draft, student: student, session: session, package: package} =
        one_off_draft(thread)

      # Booked on the web after the Draft was made.
      {:ok, _} = Enrolling.add_one_off(session, student, package, [])

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(draft, "line:teacher")
      assert failed.failure_reason == "session_id: has already been taken"
      assert length(Sales.list_purchases_for_student(student.id)) == 1
    end

    test "an exception rolls back and leaves the Draft pending", %{thread: thread} do
      %{draft: draft, student: student} = one_off_draft(thread, %{"custom_amount" => -5})

      assert_raise MatchError, fn -> Assistant.confirm_draft(draft, "line:teacher") end

      assert Repo.reload!(draft).state == "pending"
      assert Sales.list_purchases_for_student(student.id) == []
    end

    test "a Draft that is not pending is never applied", %{thread: thread} do
      {:ok, discarded} = makeup(thread, "a")
      {:ok, _} = Assistant.discard_draft(discarded)
      {:ok, replaced} = makeup(thread, "b")

      {:ok, _} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "c"}},
          replaces: replaced.id
        )

      assert {:error, :not_pending} = Assistant.confirm_draft(discarded, "line:teacher")
      assert {:error, :not_pending} = Assistant.confirm_draft(replaced, "line:teacher")
    end

    test "a makeup_request is acknowledged without a ledger row", %{thread: thread} do
      {:ok, draft} = makeup(thread, "8/17")

      assert {:ok, %Draft{state: "applied", applied_record_type: nil, applied_record_id: nil}} =
               Assistant.confirm_draft(draft, "line:teacher")
    end
  end

  describe "discard_draft/1" do
    test "discards a pending Draft", %{thread: thread} do
      {:ok, draft} = makeup(thread, "8/17")
      assert {:ok, %Draft{state: "discarded"}} = Assistant.discard_draft(draft)
    end

    test "refuses a Draft that was already settled, even from a stale copy", %{thread: thread} do
      {:ok, draft} = makeup(thread, "8/17")
      {:ok, _} = Assistant.confirm_draft(draft, "line:teacher")

      assert {:error, :not_pending} = Assistant.discard_draft(draft)
      assert Repo.reload!(draft).state == "applied"
    end
  end

  test "list_pending_drafts/0 lists pending Drafts oldest first with the student loaded", %{
    thread: thread
  } do
    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})
    {:ok, first} = makeup(thread, "a", lulu.id)
    {:ok, middle} = makeup(thread, "b")
    {:ok, last} = makeup(thread, "c")
    {:ok, _} = Assistant.discard_draft(middle)

    assert [%Draft{id: first_id, student: %{display_name: "Lulu"}}, %Draft{id: last_id}] =
             Assistant.list_pending_drafts()

    assert {first_id, last_id} == {first.id, last.id}
  end

  describe "describe_draft/2" do
    test "describes a Draft with its task", %{thread: thread} do
      draft = payment_draft(thread)
      assert %{title: "收款 Lulu NT$400"} = Assistant.describe_draft(draft, "zh-TW")
    end

    test "falls back to the kind for a retired Draft" do
      assert %{title: "attendance", lines: [], changes: [], web_path: nil} =
               Assistant.describe_draft(%Draft{kind: "attendance", parsed: %{}}, "zh-TW")
    end
  end
end
```

Edit `test/ganesha/assistant/process_event_worker_test.exs` (four edits):

1. In `test "a group message can still produce a pending draft, never an applied one"`, change
   `assert [%Assistant.Draft{state: "pending", kind: "payment"}] = drafts` to
   `assert [%Assistant.Draft{state: "pending", kind: "record_payment"}] = drafts`.
2. In `test "confirm applies a pending payment draft and replies with success"`, change `kind: "payment",` to `kind: "record_payment",`.
3. Replace the whole `test "confirm on a draft missing purchase_id explains why, without applying"` with:

```elixir
    test "confirm on a draft that no longer applies marks it failed and says why" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "record_payment", parsed: %{"amount" => 400}})

      job = enqueue_teacher_postback("action=confirm&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "failed"
      assert [{:reply, {"rt-postback", [%{type: "text", text: text}]}}] = LineMock.calls()
      assert text =~ "missing_purchase_id"
    end
```

4. In `test "discard marks a pending draft discarded"`, change
   `{:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})` to
   `{:ok, draft} = Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})`.

Edit `test/ganesha/assistant/agent_test.exs`: in `DraftingTool.call/2` change `%{kind: "unknown", parsed: %{}}` to `%{kind: "makeup_request", parsed: %{"note" => "x"}}`.

Edit `test/ganesha/assistant/tools/propose_payment_draft_test.exs`: change `assert draft.kind == "payment"` to `assert draft.kind == "record_payment"`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: FAIL — `UndefinedFunctionError`: `Ganesha.Assistant.create_draft/3`, `confirm_draft/2`, `list_pending_drafts/0` and `describe_draft/2` are undefined or private, and `%Draft{}` has no `replaced_by_id`.

- [ ] **Step 3: Generate and write the migration**

Run: `mix ecto.gen.migration extend_drafts_for_tasks`

Replace the generated file's contents with:

```elixir
defmodule Ganesha.Repo.Migrations.ExtendDraftsForTasks do
  use Ecto.Migration

  def up do
    alter table(:drafts) do
      add :failure_reason, :string
      add :replaced_by_id, references(:drafts, on_delete: :nilify_all)
      add :notified_at, :utc_datetime
    end

    create index(:drafts, [:state, :thread_id])

    # Spec §5.1: a Draft's kind is now its task's name. Applied and discarded
    # rows of retired kinds keep their old kind as history; pending ones can no
    # longer be applied, so they are discarded.
    execute "UPDATE drafts SET kind = 'record_payment' WHERE kind = 'payment'"

    execute "UPDATE drafts SET state = 'discarded' " <>
              "WHERE state = 'pending' AND kind IN ('attendance', 'unknown')"
  end

  # Pending attendance/unknown Drafts discarded by `up/0` stay discarded.
  def down do
    execute "UPDATE drafts SET kind = 'payment' WHERE kind = 'record_payment'"

    drop index(:drafts, [:state, :thread_id])

    alter table(:drafts) do
      remove :notified_at
      remove :replaced_by_id
      remove :failure_reason
    end
  end
end
```

- [ ] **Step 4: Rewrite the Draft schema**

Replace `lib/ganesha/assistant/draft.ex` with:

```elixir
defmodule Ganesha.Assistant.Draft do
  @moduledoc """
  A ledger change the assistant proposed and the teacher has not confirmed
  (GLOSSARY: Draft). `kind` is the name of the task that proposed it; `parsed`
  holds that task's details, including "before" values (spec §5.1).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.{Message, Tasks, Thread}
  alias Ganesha.People.Student

  @states ~w(pending applied discarded replaced failed)

  schema "drafts" do
    field :kind, :string
    field :parsed, :map
    field :confidence, :float, default: 1.0
    field :state, :string, default: "pending"
    field :applied_record_type, :string
    field :applied_record_id, :integer
    field :failure_reason, :string
    field :notified_at, :utc_datetime

    belongs_to :thread, Thread
    belongs_to :origin_message, Message
    belongs_to :student, Student
    belongs_to :replaced_by, __MODULE__

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def states, do: @states

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:thread_id, :origin_message_id, :kind, :student_id, :parsed, :confidence])
    |> validate_required([:thread_id, :kind, :parsed])
    |> validate_kind()
    |> put_change(:state, "pending")
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:origin_message_id)
    |> foreign_key_constraint(:student_id)
  end

  @doc "The only path to `applied`; records which ledger row it produced, if any."
  def apply_changeset(draft, applied_record_type, applied_record_id) do
    change(draft, %{
      state: "applied",
      applied_record_type: applied_record_type,
      applied_record_id: applied_record_id
    })
  end

  # Only on insert: applied and discarded rows keep retired kinds
  # (`payment` before its rename, `attendance`, `unknown`) as history.
  defp validate_kind(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset) do
    validate_change(changeset, :kind, fn :kind, kind ->
      case Tasks.fetch(kind) do
        {:ok, task} -> if task.kind() == :change, do: [], else: [kind: "is invalid"]
        :error -> [kind: "is invalid"]
      end
    end)
  end

  defp validate_kind(changeset), do: changeset
end
```

- [ ] **Step 5: Rewrite the Assistant context**

Replace `lib/ganesha/assistant.ex` with (the prompt functions and `tools/0` are carried over for now; Tasks 7 and 8 remove them):

```elixir
defmodule Ganesha.Assistant do
  @moduledoc """
  Threads, messages and Drafts for the LINE assistant. See
  docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Assistant.{Draft, Message, Tasks, Thread}
  alias Ganesha.Repo

  alias Ganesha.Assistant.Tools.{
    FindStudent,
    ProposeMakeupDraft,
    ProposePaymentDraft,
    StudentBalance,
    StudentHistory,
    TodayRoster,
    UpcomingSessions
  }

  def get_or_create_thread(source_type, source_id) do
    case Repo.get_by(Thread, source_type: source_type, source_id: source_id) do
      %Thread{} = thread ->
        {:ok, thread}

      nil ->
        %Thread{}
        |> Thread.changeset(%{source_type: source_type, source_id: source_id})
        |> Repo.insert()
    end
  end

  @supported_locales ~w(zh-TW en)

  def set_locale(%Thread{} = thread, locale) when locale in @supported_locales do
    thread
    |> Thread.changeset(%{locale: locale})
    |> Repo.update()
  end

  def set_locale(_thread, _locale), do: {:error, :invalid_locale}

  def list_messages(%Thread{} = thread) do
    Repo.all(from m in Message, where: m.thread_id == ^thread.id, order_by: m.id)
  end

  def append_message(%Thread{} = thread, role, content, tool_calls, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      thread_id: thread.id,
      role: role,
      content: content,
      tool_calls: tool_calls,
      line_message_id: opts[:line_message_id]
    })
    |> Repo.insert()
  end

  @doc """
  Inserts a pending Draft stamped with the thread's latest user message. With
  `replaces: id`, the same transaction sets that Draft to `replaced` — only if
  it belongs to this thread and is still pending (spec §2 rule 3).
  """
  def create_draft(%Thread{} = thread, attrs, opts \\ []) do
    origin = latest_user_message(thread)

    attrs =
      attrs
      |> Map.put(:thread_id, thread.id)
      |> Map.put(:origin_message_id, origin && origin.id)

    Repo.transaction(fn ->
      case %Draft{} |> Draft.changeset(attrs) |> Repo.insert() do
        {:ok, draft} ->
          replace(thread, opts[:replaces], draft)
          draft

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp replace(%Thread{id: thread_id}, old_id, %Draft{id: new_id}) when is_integer(old_id) do
    from(d in Draft,
      where: d.id == ^old_id and d.thread_id == ^thread_id and d.state == "pending"
    )
    |> Repo.update_all(set: [state: "replaced", replaced_by_id: new_id, updated_at: now()])
  end

  defp replace(_thread, _old_id, _draft), do: :ok

  defp latest_user_message(%Thread{} = thread) do
    Repo.one(
      from m in Message,
        where: m.thread_id == ^thread.id and m.role == "user",
        order_by: [desc: m.id],
        limit: 1
    )
  end

  def get_draft!(id), do: Repo.get!(Draft, id)

  @doc """
  Confirms a pending Draft (spec §4.2, §6.3). A compare-and-set claims it
  pending → applied, so concurrent confirms apply it exactly once; the task's
  `apply/2` then runs in the same transaction. A rule violation rolls it all
  back and marks the Draft `failed` with the reason. An exception rolls back,
  leaves the Draft pending, and propagates.
  """
  def confirm_draft(%Draft{} = draft, confirmed_by) do
    case Tasks.fetch(draft.kind) do
      {:ok, task} -> claim_and_apply(draft, task, confirmed_by)
      :error -> mark_failed(draft, :unknown_kind)
    end
  end

  defp claim_and_apply(draft, task, confirmed_by) do
    result =
      Repo.transaction(fn ->
        with {1, _} <- claim_pending(draft.id),
             {:ok, {record_type, record_id}} <- task.apply(draft.parsed, confirmed_by),
             {:ok, applied} <-
               draft |> Draft.apply_changeset(record_type, record_id) |> Repo.update() do
          applied
        else
          {0, _} -> Repo.rollback(:not_pending)
          {:error, reason} -> Repo.rollback({:apply_failed, reason})
        end
      end)

    case result do
      {:ok, applied} -> {:ok, applied}
      {:error, :not_pending} -> {:error, :not_pending}
      {:error, {:apply_failed, reason}} -> mark_failed(draft, reason)
    end
  end

  # Compare-and-set on `state == "pending"`: two concurrent confirms (or a
  # retried job racing a postback tap) can never both get past this point.
  # Runs inside the caller's transaction, so a later failure rolls it back.
  defp claim_pending(id) do
    Repo.update_all(from(d in Draft, where: d.id == ^id and d.state == "pending"),
      set: [state: "applied", updated_at: now()]
    )
  end

  defp mark_failed(%Draft{id: id}, reason) do
    from(d in Draft, where: d.id == ^id and d.state == "pending")
    |> Repo.update_all(
      set: [state: "failed", failure_reason: failure_reason(reason), updated_at: now()]
    )
    |> case do
      {1, _} -> {:error, {:failed, Repo.get!(Draft, id)}}
      {0, _} -> {:error, :not_pending}
    end
  end

  # Spec §7: an atom name, or the changeset's errors joined as `field: message`.
  defp failure_reason(%Ecto.Changeset{} = changeset), do: format_changeset_errors(changeset)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_binary(reason), do: reason
  defp failure_reason(reason), do: inspect(reason)

  @doc "Discards a pending Draft; compare-and-set, so a stale copy cannot undo a confirm."
  def discard_draft(%Draft{id: id}) do
    from(d in Draft, where: d.id == ^id and d.state == "pending")
    |> Repo.update_all(set: [state: "discarded", updated_at: now()])
    |> case do
      {1, _} -> {:ok, Repo.get!(Draft, id)}
      {0, _} -> {:error, :not_pending}
    end
  end

  @doc "Every pending Draft, oldest first, with its student loaded."
  def list_pending_drafts do
    Repo.all(
      from d in Draft,
        where: d.state == "pending",
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:student]
    )
  end

  @doc """
  The Draft's description from its task's `describe/2`. A Draft of a retired
  kind (kept as history) falls back to its kind as the title.
  """
  def describe_draft(%Draft{kind: kind, parsed: parsed}, locale) do
    case Tasks.fetch(kind) do
      {:ok, task} -> task.describe(parsed || %{}, locale)
      :error -> %{title: kind, lines: [], changes: [], web_path: nil}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "The full tool roster — identical for the group and teacher threads."
  def tools do
    [
      FindStudent,
      StudentBalance,
      TodayRoster,
      UpcomingSessions,
      StudentHistory,
      ProposePaymentDraft,
      ProposeMakeupDraft
    ]
  end

  defp studio_vocabulary("en") do
    """
    Reply in English. Be professional and concise. Use yoga-studio terms (class credits,
    makeup class, drop-in, trial, monthly package). You can look up students, schedules,
    and payments, and create drafts (payment, attendance, makeup) for the teacher to
    confirm — never apply a draft yourself; only she can confirm.
    """
  end

  defp studio_vocabulary(_locale) do
    """
    只用繁體中文回覆，語氣專業、簡潔，使用瑜珈教室慣用詞彙（堂數、補課、單堂、體驗、
    月課程）。你可以查詢學生、堂數與帳務資料，也可以建立「草稿」（付款、出席、補課
    需求）供她確認 — 你永遠不能把草稿直接變成正式紀錄，只有她本人確認後才算數。
    """
  end

  def teacher_system_prompt(locale \\ "zh-TW") do
    role =
      if locale == "en",
        do: "You are the studio ledger assistant speaking with the teacher directly.",
        else: "你是師父的課程記帳助理，正在跟她本人對話。"

    role <> studio_vocabulary(locale)
  end

  # Non-teacher 1:1 chats run with no tools, so the model has no studio data at
  # all; without this rule it invents class times and prices.
  def user_system_prompt("en") do
    """
    You are a helpful assistant for this yoga studio's LINE account. Reply in English. \
    Be brief and friendly. You have no access to the studio's schedule, prices, \
    class availability, bookings, or anyone's class credits. Never state or guess \
    times, dates, prices, or availability. When asked about any of these, say the \
    teacher will reply personally.
    """
  end

  def user_system_prompt(_locale) do
    """
    你是這間瑜珈教室 LINE 官方帳號的助理。只用繁體中文回覆，語氣簡短友善。\
    你看不到教室的課表、價格、名額、預約或任何人的堂數。絕對不要說出或猜測\
    上課時間、日期、價格或名額；被問到這些時，告訴對方老師會親自回覆。
    """
  end

  def group_system_prompt do
    "你正在被動觀察師父的學生群組對話，任何人都看不到你的回覆 — 你唯一能做的事是視
    情況建立草稿供師父之後確認，絕不能、也沒有管道對群組發送任何訊息。" <>
      studio_vocabulary("zh-TW")
  end

  @doc "A changeset's errors as `field: message`, joined with `; ` (spec §7)."
  def format_changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> Enum.join("; ")
  end
end
```

- [ ] **Step 6: Point the worker's confirm postback at `confirm_draft/2`, and retire the attendance tool**

In `lib/ganesha/assistant/process_event_worker.ex`, replace the whole `defp resolve_postback("confirm", draft) do … end` clause with:

```elixir
  defp resolve_postback("confirm", draft) do
    case Assistant.confirm_draft(draft, "line:teacher") do
      {:ok, _} -> "已確認並記錄。"
      {:error, :not_pending} -> "這筆草稿已經處理過了。"
      {:error, {:failed, failed}} -> "無法套用：#{failed.failure_reason}"
    end
  end
```

In `lib/ganesha/assistant/tools/propose_payment_draft.ex`, change `kind: "payment",` to `kind: "record_payment",` (its `parsed` already has the `record_payment` apply keys; the whole module is deleted in Task 7).

Delete the attendance tool and its test:

```bash
git rm lib/ganesha/assistant/tools/propose_attendance_draft.ex test/ganesha/assistant/tools/propose_attendance_draft_test.exs
```

- [ ] **Step 7: Migrate, run the tests and the compiler**

Run: `mix ecto.create --quiet && mix ecto.migrate && mix compile --warnings-as-errors && mix test test/ganesha/assistant_test.exs test/ganesha/assistant/process_event_worker_test.exs test/ganesha/assistant/agent_test.exs test/ganesha/assistant/tools`
Expected: PASS (all tests, 0 failures); compile clean. (`mix test` migrates the test database itself; the first two commands bring the dev database up to date.)

Check the data migration against legacy rows in the dev database. Roll this migration back, seed one row per legacy case, migrate again, read them back, then remove them:

```bash
mix ecto.rollback
sqlite3 ganesha_dev.db "INSERT INTO assistant_threads (source_type, source_id, inserted_at, updated_at) VALUES ('teacher', 'Umigrationcheck', datetime('now'), datetime('now'));"
sqlite3 ganesha_dev.db "INSERT INTO drafts (thread_id, kind, parsed, confidence, state, inserted_at, updated_at) SELECT id, k.kind, '{}', 1.0, k.state, datetime('now'), datetime('now') FROM assistant_threads, (SELECT 'payment' AS kind, 'pending' AS state UNION ALL SELECT 'attendance', 'pending' UNION ALL SELECT 'attendance', 'applied' UNION ALL SELECT 'unknown', 'pending' UNION ALL SELECT 'makeup_request', 'pending') AS k WHERE source_id = 'Umigrationcheck';"
mix ecto.migrate
sqlite3 ganesha_dev.db "SELECT kind, state FROM drafts WHERE thread_id = (SELECT id FROM assistant_threads WHERE source_id = 'Umigrationcheck') ORDER BY kind, state;"
sqlite3 ganesha_dev.db "DELETE FROM drafts WHERE thread_id = (SELECT id FROM assistant_threads WHERE source_id = 'Umigrationcheck'); DELETE FROM assistant_threads WHERE source_id = 'Umigrationcheck';"
```

Expected from the `SELECT`:

```
attendance|applied
attendance|discarded
makeup_request|pending
record_payment|pending
unknown|discarded
```

- [ ] **Step 8: Commit**

```bash
git add priv/repo/migrations lib/ganesha/assistant/draft.ex lib/ganesha/assistant.ex lib/ganesha/assistant/process_event_worker.ex lib/ganesha/assistant/tools/propose_payment_draft.ex test/ganesha/assistant_test.exs test/ganesha/assistant/process_event_worker_test.exs test/ganesha/assistant/agent_test.exs test/ganesha/assistant/tools/propose_payment_draft_test.exs
git commit -m "Give Drafts task kinds, replace and fail outcomes, and confirm_draft/2"
```

---
### Task 7: `Agent.run/4` over tasks; old tools removed; `max_tokens` 4096

**Files:**
- Modify: `lib/ganesha/assistant/agent.ex` (rewrite)
- Modify: `lib/ganesha/assistant/provider/anthropic.ex` (`max_tokens: 4096`)
- Modify: `lib/ganesha/assistant.ex` (delete `alias Ganesha.Assistant.Tools.{…}` and `tools/0`)
- Modify: `lib/ganesha/assistant/process_event_worker.ex` (three `Agent.run` call sites)
- Delete: `lib/ganesha/assistant/tool.ex`; `lib/ganesha/assistant/tools/{find_student,propose_makeup_draft,propose_payment_draft,student_balance,student_history,today_roster,upcoming_sessions}.ex`; `test/ganesha/assistant/tools/{find_student,propose_makeup_draft,propose_payment_draft,student_balance,student_history,today_roster,upcoming_sessions}_test.exs` (they test the removed tools)
- Test: `test/ganesha/assistant/agent_test.exs` (rewrite — every old test builds `Ganesha.Assistant.Tool` modules and calls `Agent.run/3`), `test/ganesha/assistant/provider/anthropic_test.exs` (one new test), `test/ganesha/assistant/process_event_worker_test.exs` (tool names in four stubs)

**Interfaces:**
- Consumes: `Tasks.tool_schemas/1` (Task 5), `Assistant.create_draft/3` and `Assistant.format_changeset_errors/1` (Task 6), `%Turn{}` (Task 1), `Tasks.MakeupRequest` (Task 4).
- Produces: `Ganesha.Assistant.Agent.run(thread :: Thread.t(), tasks :: [module()], system :: String.t(), history :: [Message.t()]) :: {:ok, Turn.t()} | {:error, term()}` with the §4.2 dispatch rules; `ctx` passed to tasks is `%{thread: thread, locale: thread.locale || "zh-TW", today: Clock.today()}`. A Draft corrected (`replaces_draft_id`) later in the same turn is removed from `Turn.draft_ids`.

- [ ] **Step 1: Write the failing tests**

Replace `test/ganesha/assistant/agent_test.exs` with:

```elixir
defmodule Ganesha.Assistant.AgentTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Agent, Draft, Turn}
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Assistant.Tasks.MakeupRequest

  defmodule Echo do
    @behaviour Ganesha.Assistant.Task
    def name, do: "echo"
    def kind, do: :lookup

    def tool,
      do: %{
        description: "echoes",
        input_schema: %{type: "object", properties: %{text: %{type: "string"}}}
      }

    def answer(%{"text" => text}, _ctx),
      do: {:ok, %{data: "echoed: #{text}", card: {:echo, text}}}
  end

  defmodule Pick do
    @behaviour Ganesha.Assistant.Task
    def name, do: "pick"
    def kind, do: :control

    def tool,
      do: %{description: "offers choices", input_schema: %{type: "object", properties: %{}}}

    def answer(_input, _ctx), do: {:ok, %{data: "choices shown", choices: ["A", "B"]}}
  end

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, user} = Assistant.append_message(thread, "user", "hello", nil)
    %{thread: thread, history: [user]}
  end

  defp call(id, name, input), do: %{id: id, name: name, input: input}

  # The model answers each round with the next list of tool calls, then with
  # "done". Every request's messages are kept so tests can read tool results.
  defp script(rounds) do
    Process.put(:rounds, rounds)
    Process.put(:requests, [])

    Mock.stub(fn messages, _tools, _opts ->
      Process.put(:requests, Process.get(:requests) ++ [messages])

      case Process.get(:rounds) do
        [calls | rest] ->
          Process.put(:rounds, rest)
          {:ok, %{text: nil, tool_calls: calls}}

        [] ->
          {:ok, %{text: "done", tool_calls: []}}
      end
    end)
  end

  defp tool_results do
    Process.get(:requests)
    |> List.last()
    |> Enum.filter(&(&1.role == "tool"))
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.map(& &1.content)
  end

  test "returns the model's final text as a Turn and persists it", %{
    thread: thread,
    history: history
  } do
    script([])

    assert {:ok, %Turn{text: "done", draft_ids: [], cards: [], choices: []}} =
             Agent.run(thread, [Echo], "system", history)

    assert [_user, %{role: "assistant", content: "done"}] = Assistant.list_messages(thread)
  end

  test "sends the given history, every message with tool_calls present", %{thread: thread} do
    {:ok, reply} = Assistant.append_message(thread, "assistant", "earlier reply", nil)
    {:ok, question} = Assistant.append_message(thread, "user", "and now?", nil)
    script([])

    {:ok, _} = Agent.run(thread, [Echo], "system", [reply, question])

    assert [
             [
               %{role: "assistant", content: "earlier reply", tool_calls: []},
               %{role: "user", content: "and now?", tool_calls: []}
             ]
           ] = Process.get(:requests)
  end

  test "a change task becomes a pending Draft whose id joins the Turn", %{
    thread: thread,
    history: history
  } do
    script([[call("t1", "makeup_request", %{"note" => "想補 8/17"})]])

    assert {:ok, %Turn{draft_ids: [id]}} = Agent.run(thread, [MakeupRequest], "system", history)

    assert %Draft{kind: "makeup_request", state: "pending", parsed: %{"note" => "想補 8/17"}} =
             Repo.get!(Draft, id)

    assert tool_results() == ["draft ##{id} created (makeup_request, pending confirmation)"]
  end

  test "a propose/2 error goes back to the model and writes nothing", %{
    thread: thread,
    history: history
  } do
    script([[call("t1", "makeup_request", %{"note" => " "})]])

    assert {:ok, %Turn{draft_ids: []}} = Agent.run(thread, [MakeupRequest], "system", history)
    assert tool_results() == ["makeup_request needs a note saying what the student asked for"]
    assert Repo.aggregate(Draft, :count) == 0
  end

  test "replaces_draft_id replaces the earlier Draft", %{thread: thread, history: history} do
    {:ok, old} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

    script([[call("t1", "makeup_request", %{"note" => "8/24", "replaces_draft_id" => old.id})]])

    assert {:ok, %Turn{draft_ids: [new_id]}} =
             Agent.run(thread, [MakeupRequest], "system", history)

    assert %Draft{state: "replaced", replaced_by_id: ^new_id} = Repo.reload!(old)
  end

  test "a Draft corrected later in the same turn leaves the Turn", %{
    thread: thread,
    history: history
  } do
    Process.put(:round, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      round = Process.get(:round)
      Process.put(:round, round + 1)

      case round do
        0 ->
          {:ok, %{text: nil, tool_calls: [call("t1", "makeup_request", %{"note" => "8/17"})]}}

        1 ->
          first = Repo.one!(from d in Draft, where: d.thread_id == ^thread.id)
          input = %{"note" => "8/24", "replaces_draft_id" => first.id}
          {:ok, %{text: nil, tool_calls: [call("t2", "makeup_request", input)]}}

        _ ->
          {:ok, %{text: "done", tool_calls: []}}
      end
    end)

    assert {:ok, %Turn{draft_ids: [id]}} = Agent.run(thread, [MakeupRequest], "system", history)
    assert Repo.get!(Draft, id).parsed["note"] == "8/24"
  end

  test "a lookup's card is kept only when show_card is true", %{thread: thread, history: history} do
    script([
      [
        call("t1", "echo", %{"text" => "a", "show_card" => true}),
        call("t2", "echo", %{"text" => "b"})
      ]
    ])

    assert {:ok, %Turn{cards: [{:echo, "a"}]}} = Agent.run(thread, [Echo], "system", history)
    assert tool_results() == ["echoed: a", "echoed: b"]
  end

  test "a control task's choices become the Turn's choices", %{thread: thread, history: history} do
    script([[call("t1", "pick", %{})]])
    assert {:ok, %Turn{choices: ["A", "B"]}} = Agent.run(thread, [Pick], "system", history)
  end

  test "an unknown tool name is reported back to the model", %{thread: thread, history: history} do
    script([[call("t1", "nonexistent", %{})]])

    assert {:ok, %Turn{text: "done"}} = Agent.run(thread, [Echo], "system", history)
    assert tool_results() == ["unknown tool: nonexistent"]
  end

  test "stops after six rounds", %{thread: thread, history: history} do
    Process.put(:calls, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      Process.put(:calls, Process.get(:calls) + 1)
      {:ok, %{text: nil, tool_calls: [call("t", "echo", %{"text" => "x"})]}}
    end)

    assert {:error, :max_iterations_exceeded} = Agent.run(thread, [Echo], "system", history)
    assert Process.get(:calls) == 6
  end

  test "Draft ids keep call order within a round", %{thread: thread, history: history} do
    script([
      [
        call("t1", "makeup_request", %{"note" => "a"}),
        call("t2", "makeup_request", %{"note" => "b"})
      ]
    ])

    assert {:ok, %Turn{draft_ids: ids}} = Agent.run(thread, [MakeupRequest], "system", history)
    assert length(ids) == 2

    assert ids ==
             Repo.all(
               from d in Draft, where: d.thread_id == ^thread.id, order_by: d.id, select: d.id
             )
  end

  test "persists the tool round so later turns can replay it", %{thread: thread, history: history} do
    script([[call("t1", "echo", %{"text" => "a"})]])

    {:ok, _} = Agent.run(thread, [Echo], "system", history)

    assert ["user", "assistant", "tool", "assistant"] =
             Enum.map(Assistant.list_messages(thread), & &1.role)
  end
end
```

Add to `test/ganesha/assistant/provider/anthropic_test.exs`, before the final `end`:

```elixir
  test "asks for up to 4096 output tokens" do
    parent = self()

    stub = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"content" => [%{"type" => "text", "text" => "ok"}]})
      )
    end

    assert {:ok, _} =
             Anthropic.complete([%{role: "user", content: "hi"}], [], system: "s", plug: stub)

    assert_receive {:body, %{"max_tokens" => 4096}}
  end
```

Edit `test/ganesha/assistant/process_event_worker_test.exs`:

1. Add this helper after `enqueue_teacher_postback/1`:

```elixir
  defp lulu do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1200})

    student
  end
```

2. In `test "attaches a confirm/discard action for every draft the turn created, not just the first"`, replace the two tool calls with:

```elixir
             %{id: "t1", name: "makeup_request", input: %{"note" => "8/17 補課"}},
             %{id: "t2", name: "makeup_request", input: %{"note" => "8/24 補課"}}
```

3. In `test "a group message can still produce a pending draft, never an applied one"`, add `student = lulu()` as the first line, and replace the tool call map with:

```elixir
                 %{
                   id: "t1",
                   name: "record_payment",
                   input: %{"student_id" => student.id, "amount" => 1200, "method" => "line_pay"}
                 }
```

4. In `test "unsend clears the message content and discards its pending draft"`, add `student = lulu()` as the first line and replace its tool call map with the same `record_payment` map (`"amount" => 1200`).

5. In `test "messageEdited replaces the pending draft with a fresh one from the corrected text"`, add `student = lulu()` as the first line; replace the `t1` call with `%{id: "t1", name: "record_payment", input: %{"student_id" => student.id, "amount" => 900, "method" => "line_pay"}}` and the `t2` call with `%{id: "t2", name: "record_payment", input: %{"student_id" => student.id, "amount" => 1200, "method" => "line_pay"}}`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/assistant/agent_test.exs test/ganesha/assistant/provider/anthropic_test.exs`
Expected: FAIL — `Agent.run/4 is undefined or private` and `max_tokens` assertion receives `1024`.

- [ ] **Step 3: Rewrite the Agent**

Replace `lib/ganesha/assistant/agent.ex` with:

```elixir
defmodule Ganesha.Assistant.Agent do
  @moduledoc """
  The tool loop over tasks (spec §4.2). Sends `history` plus whatever this
  turn adds, dispatches each tool call by its task's kind, persists every
  message, and returns a `Ganesha.Assistant.Turn`:

  - `:change` → `propose/2`, then `Assistant.create_draft/3` (with
    `replaces: input["replaces_draft_id"]`); the Draft id joins `draft_ids`.
  - `:lookup` → `answer/2`; the card is kept only when `input["show_card"] == true`.
  - `:control` → `answer/2`; its `choices` become `Turn.choices`.
  """

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.{Tasks, Turn}

  @max_rounds 6

  @spec run(Assistant.Thread.t(), [module()], String.t(), [Assistant.Message.t()]) ::
          {:ok, Turn.t()} | {:error, term()}
  def run(%Assistant.Thread{} = thread, tasks, system, history) do
    state = %{
      provider: Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider),
      tasks: tasks,
      schemas: Tasks.tool_schemas(tasks),
      system: system,
      ctx: %{thread: thread, locale: thread.locale || "zh-TW", today: Clock.today()}
    }

    loop(state, Enum.map(history, &to_wire/1), @max_rounds, %Turn{})
  end

  defp loop(_state, _messages, 0, _turn), do: {:error, :max_iterations_exceeded}

  defp loop(state, messages, rounds_left, %Turn{} = turn) do
    thread = state.ctx.thread

    case state.provider.complete(messages, state.schemas, system: state.system) do
      {:ok, %{text: text, tool_calls: []}} ->
        {:ok, _} = Assistant.append_message(thread, "assistant", text, nil)
        {:ok, %Turn{turn | text: text}}

      {:ok, %{text: text, tool_calls: calls}} ->
        {:ok, _} = Assistant.append_message(thread, "assistant", text, calls)
        {results, turn} = Enum.map_reduce(calls, turn, &dispatch(&1, &2, state))
        {:ok, _} = Assistant.append_message(thread, "tool", nil, results)

        messages =
          messages ++
            [
              %{role: "assistant", content: text, tool_calls: calls},
              %{role: "tool", content: nil, tool_calls: results}
            ]

        loop(state, messages, rounds_left - 1, turn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(%{id: id, name: name, input: input}, turn, state) do
    {content, turn} =
      case Enum.find(state.tasks, &(&1.name() == name)) do
        nil -> {"unknown tool: #{name}", turn}
        task -> run_task(task.kind(), task, input, turn, state.ctx)
      end

    {%{tool_use_id: id, content: content}, turn}
  end

  defp run_task(:change, task, input, %Turn{} = turn, ctx) do
    replaces = input["replaces_draft_id"]

    with {:ok, %{student_id: student_id, parsed: parsed}} <- task.propose(input, ctx),
         {:ok, draft} <-
           Assistant.create_draft(
             ctx.thread,
             %{kind: task.name(), student_id: student_id, parsed: parsed},
             replaces: replaces
           ) do
      # A Draft corrected within this same turn must not be shown as live.
      draft_ids = List.delete(turn.draft_ids, replaces) ++ [draft.id]

      {"draft ##{draft.id} created (#{task.name()}, pending confirmation)",
       %Turn{turn | draft_ids: draft_ids}}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {"could not create the draft: #{Assistant.format_changeset_errors(changeset)}", turn}

      {:error, text} ->
        {text, turn}
    end
  end

  defp run_task(:lookup, task, input, %Turn{} = turn, ctx) do
    case task.answer(input, ctx) do
      {:ok, %{data: data} = answer} ->
        cards =
          if input["show_card"] == true and Map.has_key?(answer, :card),
            do: turn.cards ++ [answer.card],
            else: turn.cards

        {data, %Turn{turn | cards: cards}}

      {:error, text} ->
        {text, turn}
    end
  end

  defp run_task(:control, task, input, %Turn{} = turn, ctx) do
    case task.answer(input, ctx) do
      {:ok, %{data: data} = answer} ->
        {data, %Turn{turn | choices: Map.get(answer, :choices, turn.choices)}}

      {:error, text} ->
        {text, turn}
    end
  end

  # Every wire message carries the same three keys whether it was built in
  # memory or reloaded: provider adapters match `%{role:, content:, tool_calls:}`.
  defp to_wire(%Assistant.Message{role: role, content: content, tool_calls: nil}) do
    %{role: role, content: content, tool_calls: []}
  end

  defp to_wire(%Assistant.Message{role: role, content: content, tool_calls: tool_calls}) do
    %{role: role, content: content, tool_calls: Enum.map(tool_calls, &atomize/1)}
  end

  # tool_calls round-trips through the {:array, :map} column as string keys;
  # the provider adapter and dispatch/3 expect atom keys.
  defp atomize(map), do: for({k, v} <- map, into: %{}, do: {String.to_existing_atom(k), v})
end
```

In `lib/ganesha/assistant/provider/anthropic.ex`, change `max_tokens: 1024,` to `max_tokens: 4096,`.

- [ ] **Step 4: Remove the old tools and switch the worker to tasks**

```bash
git rm lib/ganesha/assistant/tool.ex lib/ganesha/assistant/tools/*.ex test/ganesha/assistant/tools/*.exs
```

In `lib/ganesha/assistant.ex`, delete the `alias Ganesha.Assistant.Tools.{ … }` block and the whole `@doc "The full tool roster …"` + `def tools do … end`.

In `lib/ganesha/assistant/process_event_worker.ex`:

1. Change `alias Ganesha.Assistant.Agent` to `alias Ganesha.Assistant.{Agent, Tasks}`.
2. In `handle_group_message/2`, change
   `case Agent.run(thread, Assistant.tools(), Assistant.group_system_prompt()) do` to
   `case Agent.run(thread, Tasks.for_chat(:group), Assistant.group_system_prompt(), Assistant.list_messages(thread)) do`.
3. In `handle_message_edited/1`, replace

```elixir
        tools =
          if thread.source_type in ["teacher", "group"], do: Assistant.tools(), else: []

        case Agent.run(thread, tools, system_prompt) do
```

with

```elixir
        tasks =
          case thread.source_type do
            "teacher" -> Tasks.for_chat(:teacher)
            "group" -> Tasks.for_chat(:group)
            _ -> Tasks.for_chat(:student)
          end

        case Agent.run(thread, tasks, system_prompt, Assistant.list_messages(thread)) do
```

4. In `run_agent_and_reply/5`, replace

```elixir
    {prompt, tools} =
      case source_type do
        "teacher" -> {Assistant.teacher_system_prompt(locale), Assistant.tools()}
        _ -> {Assistant.user_system_prompt(locale), []}
      end

    case Agent.run(thread, tools, prompt) do
```

with

```elixir
    {prompt, tasks} =
      case source_type do
        "teacher" -> {Assistant.teacher_system_prompt(locale), Tasks.for_chat(:teacher)}
        _ -> {Assistant.user_system_prompt(locale), Tasks.for_chat(:student)}
      end

    case Agent.run(thread, tasks, prompt, Assistant.list_messages(thread)) do
```

5. Change the three log strings `"Ganesha.Assistant.Agent.run/3 failed` to `"Ganesha.Assistant.Agent.run/4 failed`.

(The `{:ok, %{text: reply_text, draft_ids: draft_ids}}` match in `run_agent_and_reply/5` still matches a `%Turn{}`.)

- [ ] **Step 5: Run the tests and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/assistant test/ganesha/assistant_test.exs`
Expected: PASS (0 failures); compile clean.

- [ ] **Step 6: Commit**

```bash
git add -A lib/ganesha/assistant lib/ganesha/assistant.ex test/ganesha/assistant
git commit -m "Run the assistant Agent over tasks and remove the old tools"
```

---

### Task 8: `Prompts` and `Snapshot`

**Files:**
- Create: `lib/ganesha/assistant/prompts.ex`, `lib/ganesha/assistant/snapshot.ex`
- Modify: `lib/ganesha/assistant.ex` (delete `studio_vocabulary/1`, `teacher_system_prompt/1`, `user_system_prompt/1`, `group_system_prompt/0`)
- Modify: `lib/ganesha/assistant/process_event_worker.ex` (use `Prompts`/`Snapshot`)
- Test: `test/ganesha/assistant/prompts_test.exs`, `test/ganesha/assistant/snapshot_test.exs`

**Interfaces:**
- Consumes: `Studio.list_slots/0`, `Studio.sessions_between/2` (scheduled only, slot preloaded), `Catalog.list_packages/0`, `People.list_students/0`, `Reporting.outstanding_map/0`, `Roster.count_by_session/1`, `GaneshaWeb.Fmt.{time_range/2, session_time_range/1, session_label/1, amount/1}`.
- Produces:
  - `Ganesha.Assistant.Prompts.teacher(locale, snapshot :: String.t(), summaries :: String.t() | nil) :: String.t()`, `student(locale)`, `group()`, `digest(locale)`, and `snapshot_section(snapshot) :: String.t()` (`"## Studio snapshot\n\n" <> snapshot`, used by `teacher/3` and by the Group chat's system prompt).
  - `Ganesha.Assistant.Snapshot.build(today :: Date.t()) :: String.t()` — lines `- slot <id>: …`, `- package <id>: …`, `- session <id>: <ISO date> <Wkd> <time range> <label> <style> — <n> booked` (scheduled Sessions from today−7 to today+28), `- student <id>: <name> (aka …) — owes NT$… [inactive]`.

- [ ] **Step 1: Write the failing tests**

`test/ganesha/assistant/prompts_test.exs`:

```elixir
defmodule Ganesha.Assistant.PromptsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Prompts

  test "the teacher prompt carries the snapshot, and the summaries only when there are some" do
    with_summaries = Prompts.teacher("zh-TW", "SNAPSHOT-TEXT", "SUMMARY-TEXT")
    assert with_summaries =~ "SNAPSHOT-TEXT"
    assert with_summaries =~ "SUMMARY-TEXT"

    without = Prompts.teacher("zh-TW", "SNAPSHOT-TEXT", nil)
    assert without =~ "SNAPSHOT-TEXT"
    refute without =~ "Earlier conversation"
  end

  test "each prompt follows the chat's language" do
    assert Prompts.teacher("en", "s", nil) =~ "Reply in English"
    assert Prompts.teacher("zh-TW", "s", nil) =~ "繁體中文"
    assert Prompts.student("en") =~ "Reply in English"
    assert Prompts.student("zh-TW") =~ "繁體中文"
    assert Prompts.digest("en") =~ "in English"
    assert Prompts.digest("zh-TW") =~ "繁體中文"
  end
end
```

`test/ganesha/assistant/snapshot_test.exs`:

```elixir
defmodule Ganesha.Assistant.SnapshotTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, Enrolling, People, Studio}
  alias Ganesha.Assistant.Snapshot

  test "lists slots, packages, nearby sessions with headcounts, and students with nicknames and debts" do
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

    {:ok, far} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-11-25], style: "Hatha"})
    {:ok, drop_in} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})
    {:ok, _} = People.add_alias(lulu, "露露")
    {:ok, _} = Enrolling.add_one_off(session, lulu, drop_in, [])

    snapshot = Snapshot.build(~D[2026-10-02])

    assert snapshot =~ "Today: 2026-10-02 (Fri)"
    assert snapshot =~ "- slot #{slot.id}: Wed 19:00–20:15 基礎 (Hatha)"
    assert snapshot =~ "- package #{drop_in.id}: 單堂 (drop_in, NT$400/class, 0 makeups)"
    assert snapshot =~ "- session #{session.id}: 2026-10-07 Wed 19:00–20:15 基礎 Hatha — 1 booked"
    refute snapshot =~ "- session #{far.id}:"
    assert snapshot =~ "- student #{lulu.id}: Lulu (aka 露露) — owes NT$400"
  end

  test "says when a section is empty" do
    assert Snapshot.build(~D[2026-10-02]) =~ "Students:\n(none)"
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/assistant/prompts_test.exs test/ganesha/assistant/snapshot_test.exs`
Expected: FAIL — `module Ganesha.Assistant.Prompts is not available` / `module Ganesha.Assistant.Snapshot is not available`.

- [ ] **Step 3: Write `Prompts`**

`lib/ganesha/assistant/prompts.ex`:

```elixir
defmodule Ganesha.Assistant.Prompts do
  @moduledoc """
  System prompts for the Teacher chat, Student chats, the Group chat and the
  nightly digests (spec §4.2, §6.4). Moved out of `Ganesha.Assistant`.
  """

  @spec teacher(String.t(), String.t(), String.t() | nil) :: String.t()
  def teacher(locale, snapshot, summaries) do
    [
      teacher_rules(),
      reply_language(locale),
      snapshot_section(snapshot),
      summaries_section(summaries)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # Student chats see no studio data at all; without this rule the model
  # invents class times and prices.
  @spec student(String.t()) :: String.t()
  def student("en") do
    """
    You are a helpful assistant for this yoga studio's LINE account. Reply in English. \
    Be brief and friendly. You have no access to the studio's schedule, prices, class \
    availability, bookings, or anyone's class credits. Never state or guess times, dates, \
    prices, or availability. When asked about any of these, say the teacher will reply \
    personally. If the person asks to switch language, call set_language.
    """
  end

  def student(_locale) do
    """
    你是這間瑜珈教室 LINE 官方帳號的助理。只用繁體中文回覆，語氣簡短友善。\
    你看不到教室的課表、價格、名額、預約或任何人的堂數。絕對不要說出或猜測\
    上課時間、日期、價格或名額；被問到這些時，告訴對方老師會親自回覆。\
    對方想換語言時，呼叫 set_language。
    """
  end

  @spec group() :: String.t()
  def group do
    """
    You are silently reading the teacher's LINE group with her students. Nobody sees \
    your replies, and you can never post in the group.

    Your only job: when a student's message reports a payment, asks for a single class \
    (單堂) or a trial (體驗), or asks for a makeup class, propose the matching Draft for the \
    teacher to confirm later — record_payment, book_one_off or makeup_request. Use the ids \
    in the studio snapshot. If you cannot tell which student or which Session it is, \
    propose nothing; never guess. Ignore everything else.

    End every turn with one short line saying what you did.
    """
  end

  @spec digest(String.t()) :: String.t()
  def digest(locale) do
    """
    You write the memory of the teacher's LINE chat with her studio assistant. Summarize \
    the conversation, or the daily summaries, below. Keep only what the studio ledger \
    does not record:
    - arrangements and promises (who will come when, who will pay later, what she said she would do)
    - questions still waiting for an answer
    - Drafts she discarded, and why
    - how she names students, classes and packages (nicknames, abbreviations)
    Leave out payments, bookings and other changes that were confirmed; the ledger has them.
    Write short bullet points in #{language(locale)}. If nothing is worth keeping, write only "-".
    """
  end

  @spec snapshot_section(String.t()) :: String.t()
  def snapshot_section(snapshot), do: "## Studio snapshot\n\n" <> snapshot

  defp teacher_rules do
    """
    You are the studio assistant in the teacher's own LINE chat. You help her keep her \
    yoga studio's ledger: Slots (固定班, weekly classes), Sessions (課堂, one dated class), \
    Packages (方案: 月課程, 單堂, 體驗), Enrollments (報名), Credits (補課券) and \
    No-shows (缺席).

    Rules:
    1. Use the ids in the studio snapshot when you call a task. Never invent an id, a \
    name, a date, a price or an amount. If something is not in the snapshot or in this \
    conversation, say you don't know.
    2. Every change is a Draft. Calling a task only proposes it; the teacher confirms or \
    discards it with the buttons on its card. Never say a change is done, saved or \
    recorded — say a Draft is waiting for her to confirm.
    3. When you cannot tell what she means — two students named Amy, two Tuesday classes, \
    a missing amount — call ask_teacher with the options instead of guessing.
    4. When she corrects a pending Draft, call the same task again with the corrected \
    values and replaces_draft_id set to the old Draft's id.
    5. Draft cards are shown to her automatically under your reply; don't repeat every \
    detail. Keep replies short.
    6. Lines such as "[草稿 #41 待確認] …" or "[已確認] 草稿 #41 …" record the cards and \
    buttons she saw; she did not type them.
    7. If she asks to switch language, call set_language.
    """
  end

  defp reply_language("en"), do: "Reply in English, concise and professional."

  defp reply_language(_locale) do
    "Reply in Traditional Chinese (繁體中文), concise and professional, using the studio's " <>
      "own words (堂數, 補課, 單堂, 體驗, 月課程)."
  end

  defp summaries_section(nil), do: nil
  defp summaries_section(summaries), do: "## Earlier conversation (summaries)\n\n" <> summaries

  defp language("en"), do: "English"
  defp language(_locale), do: "Traditional Chinese (繁體中文)"
end
```

- [ ] **Step 4: Write `Snapshot`**

`lib/ganesha/assistant/snapshot.ex`:

```elixir
defmodule Ganesha.Assistant.Snapshot do
  @moduledoc """
  The studio snapshot sent with every Teacher chat and Group chat message
  (spec §2 rule 4, ADR 0002): Slots, Packages, the scheduled Sessions around
  today with headcounts, and every student with nicknames and what they owe —
  each with the id the tasks take. Model-facing, so labels are English and
  ledger data is shown as stored.
  """

  alias Ganesha.{Catalog, People, Repo, Reporting, Roster, Studio}
  alias GaneshaWeb.Fmt

  @days_back 7
  @days_ahead 28
  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  @spec build(Date.t()) :: String.t()
  def build(%Date{} = today) do
    from = Date.add(today, -@days_back)
    to = Date.add(today, @days_ahead)

    Enum.join(
      [
        "Today: #{Date.to_iso8601(today)} (#{weekday(Date.day_of_week(today))})",
        section("Slots (weekly classes)", Enum.map(Studio.list_slots(), &slot_line/1)),
        section("Packages", Enum.map(Catalog.list_packages(), &package_line/1)),
        section(
          "Scheduled sessions #{Date.to_iso8601(from)} to #{Date.to_iso8601(to)}",
          session_lines(from, to)
        ),
        section("Students", student_lines())
      ],
      "\n\n"
    )
  end

  defp section(title, []), do: "#{title}:\n(none)"
  defp section(title, lines), do: Enum.join(["#{title}:" | lines], "\n")

  defp slot_line(slot) do
    "- slot #{slot.id}: #{weekday(slot.weekday)} " <>
      "#{Fmt.time_range(slot.start_time, slot.end_time)} #{slot.label} (#{slot.default_style})" <>
      if(slot.active, do: "", else: " [inactive]")
  end

  defp package_line(package) do
    "- package #{package.id}: #{package.name} (#{package.kind}, " <>
      "NT$#{Fmt.amount(package.price_per_class)}/class, #{package.included_makeups} makeups)" <>
      if(package.active, do: "", else: " [closed to new students]")
  end

  defp session_lines(from, to) do
    sessions = Studio.sessions_between(from, to)
    counts = sessions |> Enum.map(& &1.id) |> Roster.count_by_session()

    Enum.map(sessions, fn session ->
      "- session #{session.id}: #{Date.to_iso8601(session.date)} " <>
        "#{weekday(Date.day_of_week(session.date))} #{Fmt.session_time_range(session)} " <>
        "#{Fmt.session_label(session)} #{session.style} — #{Map.get(counts, session.id, 0)} booked"
    end)
  end

  defp student_lines do
    owed = Reporting.outstanding_map()

    People.list_students()
    |> Repo.preload(:aliases)
    |> Enum.map(fn student ->
      "- student #{student.id}: #{student.display_name}" <>
        aliases(student.aliases) <>
        owes(Map.get(owed, student.id, 0)) <>
        if(student.active, do: "", else: " [inactive]")
    end)
  end

  defp aliases([]), do: ""
  defp aliases(aliases), do: " (aka #{Enum.map_join(aliases, ", ", & &1.alias)})"

  defp owes(amount) when amount > 0, do: " — owes NT$#{Fmt.amount(amount)}"
  defp owes(_amount), do: ""

  defp weekday(day_of_week), do: Enum.at(@weekdays, day_of_week - 1)
end
```

- [ ] **Step 5: Move every caller onto `Prompts` and drop the old prompt functions**

In `lib/ganesha/assistant.ex`, delete `defp studio_vocabulary("en")`, `defp studio_vocabulary(_locale)`, `def teacher_system_prompt/1`, the comment and both `def user_system_prompt/1` clauses, and `def group_system_prompt/0`.

In `lib/ganesha/assistant/process_event_worker.ex`:

1. Change `alias Ganesha.Assistant.{Agent, Tasks}` to `alias Ganesha.Assistant.{Agent, Prompts, Snapshot, Tasks}` and add `alias Ganesha.Clock`.
2. In `handle_group_message/2`, change `Assistant.group_system_prompt()` to `group_system()`.
3. In `handle_message_edited/1`, replace the `system_prompt = case thread.source_type do … end` block with:

```elixir
        system_prompt =
          case thread.source_type do
            "teacher" -> Prompts.teacher(thread.locale || "zh-TW", Snapshot.build(Clock.today()), nil)
            "group" -> group_system()
            _ -> Prompts.student(thread.locale || "zh-TW")
          end
```

4. In `run_agent_and_reply/5`, replace the `{prompt, tasks} = case source_type do … end` block with:

```elixir
    {prompt, tasks} =
      case source_type do
        "teacher" ->
          {Prompts.teacher(locale, Snapshot.build(Clock.today()), nil), Tasks.for_chat(:teacher)}

        _ ->
          {Prompts.student(locale), Tasks.for_chat(:student)}
      end
```

5. Add this private function next to `handle_group_message/2`:

```elixir
  # The Group chat's tasks need ids, so it gets the snapshot too; never
  # summaries (ADR 0003).
  defp group_system do
    Prompts.group() <> "\n\n" <> Prompts.snapshot_section(Snapshot.build(Clock.today()))
  end
```

(`summaries` is `nil` until Task 13 wires `Memory` into `Conversation`.)

- [ ] **Step 6: Run the tests and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/assistant`
Expected: PASS (0 failures); compile clean.

- [ ] **Step 7: Commit**

```bash
git add lib/ganesha/assistant/prompts.ex lib/ganesha/assistant/snapshot.ex lib/ganesha/assistant.ex lib/ganesha/assistant/process_event_worker.ex test/ganesha/assistant/prompts_test.exs test/ganesha/assistant/snapshot_test.exs
git commit -m "Move assistant prompts into Prompts and add the studio Snapshot"
```

---
### Task 9: LINE client — `loading/2` and a Flex message helper

**Files:**
- Modify: `lib/ganesha/line/client_behaviour.ex`, `lib/ganesha/line/client.ex`, `lib/ganesha/line/client/mock.ex`, `config/test.exs`
- Test: `test/ganesha/line/client_test.exs`, `test/ganesha/line/client/mock_test.exs`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `@callback loading(chat_id :: String.t(), seconds :: pos_integer()) :: :ok | {:error, term()}` on `Ganesha.Line.ClientBehaviour`.
  - `Ganesha.Line.Client.loading/2` — `POST /v2/bot/chat/loading/start` with `%{chatId:, loadingSeconds:}`; any 2xx is `:ok` (LINE answers this one with 202); otherwise `{:error, {status, body}}`.
  - `Ganesha.Line.Client.flex_message(alt_text :: String.t(), contents :: map()) :: %{type: "flex", altText: String.t(), contents: map()}` — `altText` cut to 400 characters.
  - `Ganesha.Line.Client.Mock.loading/2` records `{:loading, {chat_id, seconds}}` in `calls/0` and returns `:ok`.
  - `config :ganesha, Ganesha.Line.Client, req_options: [...]` is merged into every request (`plug: {Req.Test, Ganesha.Line.Client}` in test).

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/line/client_test.exs`, before the final `end`:

```elixir
  test "loading/2 starts LINE's loading animation in the chat" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{})
    end)

    assert :ok = Client.loading("Uteacher", 20)

    assert_receive {:request, "POST", "/v2/bot/chat/loading/start",
                    %{"chatId" => "Uteacher", "loadingSeconds" => 20}}
  end

  test "loading/2 reports LINE's refusal" do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"message" => "bad"})
    end)

    assert {:error, {400, %{"message" => "bad"}}} = Client.loading("Uteacher", 20)
  end

  test "flex_message/2 wraps the contents and cuts altText to 400 characters" do
    message = Client.flex_message(String.duplicate("字", 450), %{type: "bubble"})

    assert %{type: "flex", contents: %{type: "bubble"}} = message
    assert String.length(message.altText) == 400
  end
```

Add to `test/ganesha/line/client/mock_test.exs`, before the final `end`:

```elixir
  test "records loading calls" do
    assert :ok = Mock.loading("U1", 20)
    assert Mock.calls() == [{:loading, {"U1", 20}}]
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/line/client_test.exs test/ganesha/line/client/mock_test.exs`
Expected: FAIL — `function Ganesha.Line.Client.loading/2 is undefined or private` (and `flex_message/2`, `Mock.loading/2`).

- [ ] **Step 3: Implement**

Replace `lib/ganesha/line/client_behaviour.ex` with:

```elixir
defmodule Ganesha.Line.ClientBehaviour do
  @moduledoc "Contract shared by `Ganesha.Line.Client` and `Ganesha.Line.Client.Mock`."

  @callback reply(reply_token :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback push(to :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback loading(chat_id :: String.t(), seconds :: pos_integer()) :: :ok | {:error, term()}
  @callback get_group_member(group_id :: String.t(), user_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
```

In `lib/ganesha/line/client.ex`:

1. Add after `push/2`:

```elixir
  @doc "Shows LINE's loading animation in a 1:1 chat while the assistant thinks (spec §6.1)."
  @impl true
  def loading(chat_id, seconds) when is_integer(seconds) and seconds > 0 do
    post("/v2/bot/chat/loading/start", %{chatId: chat_id, loadingSeconds: seconds})
  end
```

2. Replace `defp post/2` and `defp req/0` with:

```elixir
  defp post(path, body) do
    case Req.post(req(), url: path, json: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    token = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_access_token)
    options = :ganesha |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    Req.new([base_url: @base_url, headers: [{"authorization", "Bearer #{token}"}]] ++ options)
  end
```

3. Add after `text_message/2`:

```elixir
  @doc "A Flex message holding one bubble or carousel; LINE caps `altText` at 400 characters."
  def flex_message(alt_text, contents) when is_binary(alt_text) and is_map(contents) do
    %{type: "flex", altText: String.slice(alt_text, 0, 400), contents: contents}
  end
```

In `lib/ganesha/line/client/mock.ex`, add after `push/2`:

```elixir
  @impl true
  def loading(chat_id, seconds) do
    record(:loading, {chat_id, seconds})
    :ok
  end
```

In `config/test.exs`, add after `config :ganesha, :line_client, Ganesha.Line.Client.Mock`:

```elixir
# The real LINE client only ever talks to Req.Test stubs in tests.
config :ganesha, Ganesha.Line.Client, req_options: [plug: {Req.Test, Ganesha.Line.Client}]
```

- [ ] **Step 4: Run the tests and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/line`
Expected: PASS (0 failures); compile clean.

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/line/client_behaviour.ex lib/ganesha/line/client.ex lib/ganesha/line/client/mock.ex config/test.exs test/ganesha/line/client_test.exs test/ganesha/line/client/mock_test.exs
git commit -m "Add LINE loading animation and Flex message helper"
```

---

### Task 10: `Labels` and the Draft card (`Cards`)

**Files:**
- Create: `lib/ganesha/line/labels.ex`, `lib/ganesha/line/cards.ex`
- Test: `test/ganesha/line/labels_test.exs`, `test/ganesha/line/cards_test.exs`

**Interfaces:**
- Consumes: `Assistant.describe_draft/2` (Task 6), `GaneshaWeb.Endpoint.url/0`.
- Produces:
  - `Ganesha.Line.Labels.t(key :: atom(), locale :: String.t() | nil, bindings :: keyword() \\ []) :: String.t()` — `t/2` is the spec contract; `t/3` fills `%{name}` placeholders. Any locale other than `"en"` gets zh-TW. Keys: `:confirm :discard :open_web :more_drafts(count) :choose :draft :pending :options :confirmed(title) :discarded(title) :failed(title, reason) :already_handled :replaced :not_found :exception :tag_confirmed :tag_discarded :tag_failed :tag_already_handled :tag_replaced :tag_exception :apology :unknown_action :welcome`.
  - `Ganesha.Line.Cards.render({:draft, Draft.t()}, locale) :: map()` — one Flex bubble.
  - `Ganesha.Line.Cards.history_line({:draft, Draft.t()}, locale) :: String.t()` — `"[草稿 #41 待確認] <title>"` / `"[Draft #41 pending] <title>"`.
  - `Ganesha.Line.Cards.draft_carousel([Draft.t()], locale) :: %{type: "carousel", contents: [bubble]}` — at most 12 bubbles.

- [ ] **Step 1: Write the failing tests**

`test/ganesha/line/labels_test.exs`:

```elixir
defmodule Ganesha.Line.LabelsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Line.Labels

  test "speaks the chat's language, defaulting to Traditional Chinese" do
    assert Labels.t(:confirm, "zh-TW") == "確認"
    assert Labels.t(:confirm, "en") == "Confirm"
    assert Labels.t(:confirm, nil) == "確認"
  end

  test "fills in an outcome's details (spec §6.3)" do
    assert Labels.t(:failed, "zh-TW", title: "收款 Amy NT$3,200", reason: "missing_purchase_id") ==
             "無法套用：收款 Amy NT$3,200（missing_purchase_id）"

    assert Labels.t(:failed, "en", title: "Payment Amy NT$3,200", reason: "missing_purchase_id") ==
             "Couldn't apply: Payment Amy NT$3,200 (missing_purchase_id)"
  end
end
```

`test/ganesha/line/cards_test.exs`:

```elixir
defmodule Ganesha.Line.CardsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Cards

  defp payment(id) do
    %Draft{
      id: id,
      kind: "record_payment",
      state: "pending",
      parsed: %{
        "student_id" => 7,
        "student_name" => "Lulu",
        "purchase_id" => 3,
        "amount" => 1600,
        "method" => "line_pay",
        "paid_on" => "2026-10-02",
        "package_name" => "月課程",
        "before_owed" => 1600
      }
    }
  end

  test "a Draft card shows its title, lines and before → after, with Confirm, Discard and the web page" do
    bubble = Cards.render({:draft, payment(41)}, "zh-TW")

    assert %{type: "bubble", header: %{contents: [%{type: "text", text: "收款 Lulu NT$1,600"}]}} =
             bubble

    texts = Enum.map(bubble.body.contents, & &1.text)
    assert "方案：月課程" in texts
    assert "尚欠: NT$1,600 → NT$0" in texts

    assert [confirm, discard, web] = bubble.footer.contents
    assert confirm.action == %{type: "postback", label: "確認", data: "action=confirm&draft_id=41"}
    assert discard.action == %{type: "postback", label: "捨棄", data: "action=discard&draft_id=41"}
    assert web.action.type == "uri"
    assert String.ends_with?(web.action.uri, "/students/7")
  end

  test "a change with no before value shows only the after value" do
    draft = %Draft{
      id: 6,
      kind: "book_one_off",
      parsed: %{
        "session_id" => 9,
        "student_name" => "Lulu",
        "package_name" => "單堂",
        "package_kind" => "drop_in",
        "price" => 400,
        "session_date" => "2026-10-07",
        "session_label" => "基礎",
        "session_time" => "19:00–20:15",
        "before_count" => 3
      }
    }

    texts = Enum.map(Cards.render({:draft, draft}, "zh-TW").body.contents, & &1.text)
    assert "名單: 3 人 → 4 人" in texts
    assert "應付: NT$400" in texts
  end

  test "no web button without a web path, and labels follow the chat's language" do
    draft = %Draft{id: 5, kind: "makeup_request", parsed: %{"note" => "想補 8/17"}}
    bubble = Cards.render({:draft, draft}, "en")

    assert [%{action: %{label: "Confirm"}}, %{action: %{label: "Discard"}}] =
             bubble.footer.contents

    assert [%{text: "想補 8/17"}] = bubble.body.contents
  end

  test "history_line/2 names the Draft for the model" do
    assert Cards.history_line({:draft, payment(41)}, "zh-TW") == "[草稿 #41 待確認] 收款 Lulu NT$1,600"

    assert Cards.history_line({:draft, payment(41)}, "en") ==
             "[Draft #41 pending] Payment Lulu NT$1,600"
  end

  test "a Draft carousel holds at most 12 bubbles" do
    carousel = Cards.draft_carousel(Enum.map(1..13, &payment/1), "zh-TW")

    assert %{type: "carousel", contents: bubbles} = carousel
    assert length(bubbles) == 12
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/line/labels_test.exs test/ganesha/line/cards_test.exs`
Expected: FAIL — `module Ganesha.Line.Labels is not available` / `module Ganesha.Line.Cards is not available`.

- [ ] **Step 3: Write `Labels`**

`lib/ganesha/line/labels.ex`:

```elixir
defmodule Ganesha.Line.Labels do
  @moduledoc """
  Every card, button and outcome label the LINE assistant shows, per locale
  (spec §6.2, §6.3, §6.5). Ledger data is never translated; only these are.
  """

  @labels %{
    confirm: {"確認", "Confirm"},
    discard: {"捨棄", "Discard"},
    open_web: {"在網頁開啟", "Open on web"},
    more_drafts:
      {"還有 %{count} 筆草稿沒有顯示，傳「待確認草稿」可以看全部。",
       "%{count} more drafts are not shown; send “待確認草稿” to see them all."},
    choose: {"請選擇：", "Please choose:"},
    draft: {"草稿", "Draft"},
    pending: {"待確認", "pending"},
    options: {"選項", "Options"},
    confirmed: {"已確認：%{title}", "Confirmed: %{title}"},
    discarded: {"已捨棄：%{title}", "Discarded: %{title}"},
    failed: {"無法套用：%{title}（%{reason}）", "Couldn't apply: %{title} (%{reason})"},
    already_handled: {"這筆草稿已經處理過了。", "This draft was already handled."},
    replaced: {"這筆草稿已被取代。", "This draft was replaced."},
    not_found: {"找不到這筆草稿。", "Draft not found."},
    exception: {"記錄失敗，請稍後再試。", "Something went wrong; please try again."},
    tag_confirmed: {"已確認", "Confirmed"},
    tag_discarded: {"已捨棄", "Discarded"},
    tag_failed: {"無法套用", "Couldn't apply"},
    tag_already_handled: {"已處理過", "Already handled"},
    tag_replaced: {"已被取代", "Replaced"},
    tag_exception: {"確認失敗", "Confirm failed"},
    apology:
      {"抱歉，我現在無法處理這則訊息，請稍後再試一次。",
       "Sorry, I couldn't process that message. Please try again later."},
    unknown_action: {"無法辨識的操作。", "Unrecognized action."},
    welcome: {"好的！有什麼需要我幫忙的？", "Thanks! How can I help you today?"}
  }

  @spec t(atom(), String.t() | nil, keyword()) :: String.t()
  def t(key, locale, bindings \\ []) do
    {zh, en} = Map.fetch!(@labels, key)
    template = if locale == "en", do: en, else: zh

    Enum.reduce(bindings, template, fn {name, value}, text ->
      String.replace(text, "%{#{name}}", to_string(value))
    end)
  end
end
```

- [ ] **Step 4: Write `Cards`**

`lib/ganesha/line/cards.ex`:

```elixir
defmodule Ganesha.Line.Cards do
  @moduledoc """
  The fixed LINE card designs (spec §2 rule 6, §6.2). The model picks a card;
  this module lays it out from stored values only. Slice 1 has the Draft card
  and the Draft carousel; the lookup cards arrive in slice 2.
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Labels

  @max_bubbles 12

  @spec render(Ganesha.Assistant.Task.card(), String.t()) :: map()
  def render({:draft, %Draft{} = draft}, locale) do
    description = Assistant.describe_draft(draft, locale)

    %{
      type: "bubble",
      header: %{
        type: "box",
        layout: "vertical",
        contents: [%{type: "text", text: description.title, weight: "bold", wrap: true}]
      },
      footer: footer(draft, description.web_path, locale)
    }
    |> put_body(description.lines ++ Enum.map(description.changes, &change_line/1))
  end

  @spec history_line(Ganesha.Assistant.Task.card(), String.t()) :: String.t()
  def history_line({:draft, %Draft{} = draft}, locale) do
    title = Assistant.describe_draft(draft, locale).title
    "[#{Labels.t(:draft, locale)} ##{draft.id} #{Labels.t(:pending, locale)}] #{title}"
  end

  @spec draft_carousel([Draft.t()], String.t()) :: map()
  def draft_carousel(drafts, locale) do
    %{
      type: "carousel",
      contents: drafts |> Enum.take(@max_bubbles) |> Enum.map(&render({:draft, &1}, locale))
    }
  end

  defp change_line({label, nil, after_value}), do: "#{label}: #{after_value}"
  defp change_line({label, before, after_value}), do: "#{label}: #{before} → #{after_value}"

  # LINE rejects a box with no contents, so a card with nothing to list has no body.
  defp put_body(bubble, []), do: bubble

  defp put_body(bubble, lines) do
    Map.put(bubble, :body, %{
      type: "box",
      layout: "vertical",
      spacing: "sm",
      contents: Enum.map(lines, &%{type: "text", text: &1, size: "sm", wrap: true})
    })
  end

  defp footer(draft, web_path, locale) do
    buttons =
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
      ] ++ web_button(web_path, locale)

    %{type: "box", layout: "vertical", spacing: "sm", contents: buttons}
  end

  defp web_button(nil, _locale), do: []

  defp web_button(path, locale) do
    [
      button("link", %{
        type: "uri",
        label: Labels.t(:open_web, locale),
        uri: GaneshaWeb.Endpoint.url() <> path
      })
    ]
  end

  defp button(style, action), do: %{type: "button", style: style, height: "sm", action: action}
end
```

- [ ] **Step 5: Run the tests and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/line/labels_test.exs test/ganesha/line/cards_test.exs`
Expected: PASS (7 tests, 0 failures); compile clean.

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/line/labels.ex lib/ganesha/line/cards.ex test/ganesha/line/labels_test.exs test/ganesha/line/cards_test.exs
git commit -m "Add LINE labels and the Draft card"
```

---

### Task 11: `Reply` — pack a Turn into ≤ 5 messages

**Files:**
- Create: `lib/ganesha/line/reply.ex`
- Test: `test/ganesha/line/reply_test.exs`

**Interfaces:**
- Consumes: `%Turn{}` (Task 1), `Cards.render/2`, `Cards.history_line/2`, `Cards.draft_carousel/2` (Task 10), `Labels.t/3` (Task 10), `Client.text_message/1`, `Client.flex_message/2` (Task 9).
- Produces:
  - `Ganesha.Line.Reply.build(turn, drafts :: [Draft.t()], locale) :: [map()]` — ≤ 5 messages: text (if any; plus the "more drafts" line when > 12 Drafts) → lookup cards (dropped beyond the limit) → one carousel of the first 12 Drafts; `choices` become `quickReply` items `%{type: "action", action: %{type: "message", label: c, text: c}}` on the last message (a `Labels.t(:choose)` text is added when there is no other message); `[]` for an empty turn.
  - `Ganesha.Line.Reply.history_text(turn, drafts, locale) :: String.t() | nil` — one line per shown lookup card, one per Draft, and `"[選項] A / B"` for choices; `nil` when there is none.

- [ ] **Step 1: Write the failing test**

`test/ganesha/line/reply_test.exs`:

```elixir
defmodule Ganesha.Line.ReplyTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.{Draft, Turn}
  alias Ganesha.Line.Reply

  defp draft(id) do
    %Draft{
      id: id,
      kind: "makeup_request",
      state: "pending",
      parsed: %{"note" => "想補 #{id}", "student_id" => id, "student_name" => "學生#{id}"}
    }
  end

  defp drafts(n), do: Enum.map(1..n, &draft/1)

  test "text alone is one text message" do
    assert [%{type: "text", text: "好的"}] = Reply.build(%Turn{text: "好的"}, [], "zh-TW")
  end

  test "text first, then one Draft carousel" do
    assert [
             %{type: "text", text: "已建立草稿。"},
             %{type: "flex", altText: alt, contents: %{type: "carousel", contents: [_, _]}}
           ] = Reply.build(%Turn{text: "已建立草稿。", draft_ids: [1, 2]}, drafts(2), "zh-TW")

    assert alt =~ "[草稿 #1 待確認] 補課需求 學生1"
  end

  test "more than 12 Drafts: the carousel shows 12 and the text says how many more" do
    assert [text, carousel] = Reply.build(%Turn{text: "好了"}, drafts(14), "zh-TW")
    assert length(carousel.contents.contents) == 12
    assert text.text =~ "還有 2 筆草稿"
    assert text.text =~ "待確認草稿"
  end

  test "never more than 5 messages: lookup cards past the limit are dropped" do
    cards = Enum.map(1..6, &{:draft, draft(&1)})
    messages = Reply.build(%Turn{text: "看看", cards: cards}, drafts(1), "zh-TW")

    assert [
             %{type: "text"},
             %{contents: %{type: "bubble"}},
             %{contents: %{type: "bubble"}},
             %{contents: %{type: "bubble"}},
             %{contents: %{type: "carousel"}}
           ] = messages
  end

  test "every Flex message carries an altText of at most 400 characters" do
    long = %Draft{
      id: 1,
      kind: "makeup_request",
      parsed: %{"note" => "x", "student_name" => String.duplicate("長", 500)}
    }

    messages = Reply.build(%Turn{cards: [{:draft, long}]}, List.duplicate(long, 3), "zh-TW")

    assert length(messages) == 2

    for %{type: "flex"} = message <- messages do
      assert is_binary(message.altText)
      assert message.altText != ""
      assert String.length(message.altText) <= 400
    end
  end

  test "choices become quick replies on the last message only" do
    assert [text, carousel] =
             Reply.build(%Turn{text: "哪一位？", choices: ["週二", "週四"]}, drafts(1), "zh-TW")

    refute Map.has_key?(text, :quickReply)

    assert [%{type: "action", action: %{type: "message", label: "週二", text: "週二"}}, _] =
             carousel.quickReply.items
  end

  test "choices with nothing else to say still get a message to ride on" do
    assert [%{type: "text", text: "請選擇：", quickReply: %{items: [_, _]}}] =
             Reply.build(%Turn{choices: ["A", "B"]}, [], "zh-TW")
  end

  test "an empty turn sends nothing" do
    assert Reply.build(%Turn{}, [], "zh-TW") == []
  end

  describe "history_text/3" do
    test "names every Draft and the choices offered" do
      assert Reply.history_text(%Turn{choices: ["A", "B"]}, drafts(2), "zh-TW") ==
               "[草稿 #1 待確認] 補課需求 學生1\n[草稿 #2 待確認] 補課需求 學生2\n[選項] A / B"
    end

    test "is nil when the turn sent no cards" do
      assert Reply.history_text(%Turn{text: "hi"}, [], "zh-TW") == nil
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/ganesha/line/reply_test.exs`
Expected: FAIL — `module Ganesha.Line.Reply is not available`.

- [ ] **Step 3: Write `Reply`**

`lib/ganesha/line/reply.ex`:

```elixir
defmodule Ganesha.Line.Reply do
  @moduledoc """
  Packs a `Ganesha.Assistant.Turn` into at most five LINE messages (spec §6.2):
  the text, then lookup cards (one bubble each), then one Draft carousel.
  Lookup cards that do not fit are dropped; Drafts past twelve are counted in
  the text instead. Choices ride on the last message as quick replies.
  """

  alias Ganesha.Assistant.{Draft, Turn}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_messages 5
  @max_bubbles 12
  @max_text 5000

  @spec build(Turn.t(), [Draft.t()], String.t()) :: [map()]
  def build(%Turn{} = turn, drafts, locale) do
    plan = plan(turn, drafts, locale)

    texts = if plan.text, do: [Client.text_message(plan.text)], else: []

    cards =
      Enum.map(
        plan.cards,
        &Client.flex_message(Cards.history_line(&1, locale), Cards.render(&1, locale))
      )

    carousel =
      case plan.shown do
        [] ->
          []

        shown ->
          alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))
          [Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))]
      end

    attach_choices(texts ++ cards ++ carousel, turn.choices, locale)
  end

  @spec history_text(Turn.t(), [Draft.t()], String.t()) :: String.t() | nil
  def history_text(%Turn{} = turn, drafts, locale) do
    plan = plan(turn, drafts, locale)

    lines =
      Enum.map(plan.cards, &Cards.history_line(&1, locale)) ++
        Enum.map(drafts, &Cards.history_line({:draft, &1}, locale)) ++
        choices_line(turn.choices, locale)

    if lines == [], do: nil, else: Enum.join(lines, "\n")
  end

  defp plan(turn, drafts, locale) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)
    text = text(turn.text, length(hidden), locale)
    used = if(text, do: 1, else: 0) + if(shown == [], do: 0, else: 1)

    %{text: text, shown: shown, cards: Enum.take(turn.cards, max(@max_messages - used, 0))}
  end

  defp text(text, hidden, locale) do
    more = if hidden > 0, do: Labels.t(:more_drafts, locale, count: hidden)

    case Enum.reject([text, more], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> parts |> Enum.join("\n\n") |> String.slice(0, @max_text)
    end
  end

  defp attach_choices(messages, [], _locale), do: messages

  defp attach_choices([], choices, locale),
    do: attach_choices([Client.text_message(Labels.t(:choose, locale))], choices, locale)

  defp attach_choices(messages, choices, _locale) do
    quick_reply = %{
      items:
        Enum.map(choices, &%{type: "action", action: %{type: "message", label: &1, text: &1}})
    }

    List.update_at(messages, -1, &Map.put(&1, :quickReply, quick_reply))
  end

  defp choices_line([], _locale), do: []

  defp choices_line(choices, locale),
    do: ["[#{Labels.t(:options, locale)}] #{Enum.join(choices, " / ")}"]
end
```

- [ ] **Step 4: Run the test and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/line/reply_test.exs`
Expected: PASS (10 tests, 0 failures); compile clean.

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/line/reply.ex test/ganesha/line/reply_test.exs
git commit -m "Pack assistant turns into LINE replies"
```

---

### Task 12: `Memory` read side — `assistant_digests`, `history/3`, `summaries/2`

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_assistant_digests.exs` (via `mix ecto.gen.migration`)
- Create: `lib/ganesha/assistant/digest.ex`, `lib/ganesha/assistant/memory.ex`
- Modify: `lib/ganesha/assistant/message.ex` (add `@type t`)
- Test: `test/ganesha/assistant/memory_test.exs`

**Interfaces:**
- Consumes: `Clock.today/1`, `Clock.to_taipei_date/1`, `Assistant.append_message/4`.
- Produces:
  - `assistant_digests` table and `Ganesha.Assistant.Digest` (`thread_id`, `kind` ∈ `daily | weekly`, `period_start :date`, `period_end :date`, `content`, timestamps; unique `[:thread_id, :kind, :period_start]`), `Digest.changeset/2`, `@type t`.
  - `Ganesha.Assistant.Memory.history(thread, :teacher | :student, now :: DateTime.t()) :: [Message.t()]` (§6.4 Level 1).
  - `Ganesha.Assistant.Memory.summaries(thread, today :: Date.t()) :: String.t() | nil` — Level 3 then Level 2, each rendered `"[<start> – <end>]\n<content>"` (weekly) or `"[<date>]\n<content>"` (daily), joined by a blank line.
  - `Ganesha.Assistant.Message.t()` type.

- [ ] **Step 1: Write the failing test**

`test/ganesha/assistant/memory_test.exs`:

```elixir
defmodule Ganesha.Assistant.MemoryTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Digest, Memory}

  # 12:00 in Asia/Taipei on 2026-10-02.
  @now ~U[2026-10-02 04:00:00Z]
  @today ~D[2026-10-02]
  @yesterday ~U[2026-10-01 04:00:00Z]
  @this_morning ~U[2026-10-02 01:00:00Z]

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{thread: thread}
  end

  defp put(thread, role, content, at, tool_calls \\ nil) do
    {:ok, message} = Assistant.append_message(thread, role, content, tool_calls)
    message |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  # `n` exchanges one minute apart after `start`: user "u<i>", optionally a
  # tool round, then the assistant's final "a<i>".
  defp exchanges(thread, n, start, opts \\ []) do
    for i <- 1..n do
      at = DateTime.add(start, i * 60)
      put(thread, "user", "u#{i}", at)

      if opts[:tools] do
        put(thread, "assistant", nil, at, [%{id: "t#{i}", name: "echo", input: %{}}])
        put(thread, "tool", nil, at, [%{tool_use_id: "t#{i}", content: "ok"}])
      end

      put(thread, "assistant", "a#{i}", at)
    end
  end

  defp counted(messages) do
    Enum.filter(
      messages,
      &(&1.role == "user" or (&1.role == "assistant" and is_nil(&1.tool_calls)))
    )
  end

  defp digest(thread, kind, from, to, content) do
    Repo.insert!(%Digest{
      thread_id: thread.id,
      kind: kind,
      period_start: from,
      period_end: to,
      content: content
    })
  end

  describe "history/3" do
    test "keeps the last 30 counted messages and every message after the oldest of them", %{
      thread: thread
    } do
      exchanges(thread, 20, @yesterday, tools: true)

      history = Memory.history(thread, :teacher, @now)

      assert length(counted(history)) == 30
      assert %{role: "user", content: "u6"} = hd(history)
      assert length(history) == 60
    end

    test "always starts at a user message", %{thread: thread} do
      exchanges(thread, 16, @yesterday)
      put(thread, "assistant", "[已確認] 草稿 #1 收款 Lulu NT$400", DateTime.add(@yesterday, 3600))

      history = Memory.history(thread, :teacher, @now)

      assert %{role: "user", content: "u3"} = hd(history)
      assert length(counted(history)) == 29
    end

    test "takes all of today's messages when there are more than 30", %{thread: thread} do
      exchanges(thread, 10, @yesterday)
      exchanges(thread, 20, @this_morning)

      history = Memory.history(thread, :teacher, @now)

      assert length(counted(history)) == 40
      assert %{content: "u1", inserted_at: ~U[2026-10-02 01:01:00Z]} = hd(history)
    end

    test "caps today's messages at 100 counted", %{thread: thread} do
      exchanges(thread, 60, ~U[2026-10-02 00:00:00Z])

      history = Memory.history(thread, :teacher, @now)

      assert length(counted(history)) == 100
      assert %{role: "user", content: "u11"} = hd(history)
    end

    test "a Student chat keeps only the last 30 counted messages" do
      {:ok, student_chat} = Assistant.get_or_create_thread("user", "Ustudent")
      exchanges(student_chat, 20, @this_morning)

      assert length(counted(Memory.history(student_chat, :student, @now))) == 30
    end

    test "an empty thread has no history", %{thread: thread} do
      assert Memory.history(thread, :teacher, @now) == []
    end
  end

  describe "summaries/2" do
    test "is nil when there are no digests", %{thread: thread} do
      assert Memory.summaries(thread, @today) == nil
    end

    test "weeks that ended at least 15 days ago, then the days after the newest week", %{
      thread: thread
    } do
      put(thread, "user", "今天的訊息", @this_morning)
      digest(thread, "weekly", ~D[2026-06-15], ~D[2026-06-21], "too old")
      digest(thread, "weekly", ~D[2026-09-07], ~D[2026-09-13], "week A")
      digest(thread, "weekly", ~D[2026-09-21], ~D[2026-09-27], "too recent")
      digest(thread, "daily", ~D[2026-09-10], ~D[2026-09-10], "inside week A")
      digest(thread, "daily", ~D[2026-09-14], ~D[2026-09-14], "day 14")
      digest(thread, "daily", ~D[2026-09-30], ~D[2026-09-30], "day 30")

      assert Memory.summaries(thread, @today) ==
               "[2026-09-07 – 2026-09-13]\nweek A\n\n[2026-09-14]\nday 14\n\n[2026-09-30]\nday 30"
    end

    test "without weeks: days from the last 14 days, up to the oldest message in the window", %{
      thread: thread
    } do
      put(thread, "user", "那天的訊息", ~U[2026-09-28 04:00:00Z])
      digest(thread, "daily", ~D[2026-09-17], ~D[2026-09-17], "15 days ago")
      digest(thread, "daily", ~D[2026-09-18], ~D[2026-09-18], "14 days ago")
      digest(thread, "daily", ~D[2026-09-28], ~D[2026-09-28], "window day")
      digest(thread, "daily", ~D[2026-09-29], ~D[2026-09-29], "inside the window")

      assert Memory.summaries(thread, @today) ==
               "[2026-09-18]\n14 days ago\n\n[2026-09-28]\nwindow day"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/ganesha/assistant/memory_test.exs`
Expected: FAIL — compile error `Ganesha.Assistant.Digest.__struct__/1 is undefined` (module not available).

- [ ] **Step 3: Generate and write the migration**

Run: `mix ecto.gen.migration create_assistant_digests`

Replace the generated file's contents with:

```elixir
defmodule Ganesha.Repo.Migrations.CreateAssistantDigests do
  use Ecto.Migration

  def change do
    create table(:assistant_digests) do
      add :thread_id, references(:assistant_threads, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assistant_digests, [:thread_id, :kind, :period_start])
  end
end
```

- [ ] **Step 4: Write `Digest`, the `Message` type, and `Memory`**

`lib/ganesha/assistant/digest.ex`:

```elixir
defmodule Ganesha.Assistant.Digest do
  @moduledoc """
  A daily or weekly summary of the Teacher chat (spec §5.2, §6.4). Only the
  Teacher chat has digests (ADR 0003).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.Thread

  @kinds ~w(daily weekly)

  schema "assistant_digests" do
    field :kind, :string
    field :period_start, :date
    field :period_end, :date
    field :content, :string

    belongs_to :thread, Thread

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(digest, attrs) do
    digest
    |> cast(attrs, [:thread_id, :kind, :period_start, :period_end, :content])
    |> validate_required([:thread_id, :kind, :period_start, :period_end, :content])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:thread_id)
    |> unique_constraint([:thread_id, :kind, :period_start],
      name: "assistant_digests_thread_id_kind_period_start_index"
    )
  end
end
```

In `lib/ganesha/assistant/message.ex`, add right after the `schema "assistant_messages" do … end` block:

```elixir
  @type t :: %__MODULE__{}
```

`lib/ganesha/assistant/memory.ex`:

```elixir
defmodule Ganesha.Assistant.Memory do
  @moduledoc """
  What the model remembers of a chat (spec §6.4).

  - A counted message is a `user` message, or an `assistant` message with no
    tool calls.
  - Level 1: the last 30 counted messages and every message after the oldest
    of them; when more than 30 counted messages were sent today
    (Asia/Taipei), all of today's, up to 100 counted. The window always starts
    at a `user` message. Student chats: the last 30 counted only.
  - Level 3: weekly digests whose `period_end` is at least 15 days before
    today and whose `period_start` is within 90 days.
  - Level 2: daily digests after the newest Level 3 week (or within the last
    14 days when there is none), up to and including the date of the oldest
    Level 1 message.
  """

  import Ecto.Query

  alias Ganesha.{Clock, Repo}
  alias Ganesha.Assistant.{Digest, Message, Thread}

  @window 30
  @today_cap 100
  @taipei_offset_seconds 8 * 60 * 60

  @spec history(Thread.t(), :teacher | :student, DateTime.t()) :: [Message.t()]
  def history(%Thread{} = thread, kind, %DateTime{} = now) when kind in [:teacher, :student] do
    case window_start(thread, kind, Clock.today(now)) do
      nil ->
        []

      %{id: start_id} ->
        Repo.all(
          from m in Message,
            where: m.thread_id == ^thread.id and m.id >= ^start_id,
            order_by: m.id
        )
    end
  end

  @spec summaries(Thread.t(), Date.t()) :: String.t() | nil
  def summaries(%Thread{} = thread, %Date{} = today) do
    weeks = weekly_digests(thread, today)
    days = daily_digests(thread, today, weeks)

    case weeks ++ days do
      [] -> nil
      digests -> Enum.map_join(digests, "\n\n", &render/1)
    end
  end

  # The oldest counted message of the Level 1 window, or nil when the window
  # holds no user message.
  defp window_start(thread, kind, today) do
    counted =
      Repo.all(
        from m in Message,
          where: m.thread_id == ^thread.id,
          where: m.role == "user" or (m.role == "assistant" and is_nil(m.tool_calls)),
          order_by: [desc: m.id],
          limit: @today_cap,
          select: %{id: m.id, role: m.role, inserted_at: m.inserted_at}
      )

    counted
    |> Enum.take(window_size(counted, kind, today))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.role != "user"))
    |> List.first()
  end

  defp window_size(_counted, :student, _today), do: @window

  defp window_size(counted, :teacher, today) do
    start = day_start(today)
    sent_today = Enum.count(counted, &(DateTime.compare(&1.inserted_at, start) != :lt))
    max(sent_today, @window)
  end

  defp weekly_digests(thread, today) do
    ended_by = Date.add(today, -15)
    started_from = Date.add(today, -90)

    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == "weekly",
        where: d.period_end <= ^ended_by and d.period_start >= ^started_from,
        order_by: d.period_start
    )
  end

  defp daily_digests(thread, today, weeks) do
    after_date =
      case List.last(weeks) do
        nil -> Date.add(today, -15)
        week -> week.period_end
      end

    until = level1_start_date(thread, today) || today

    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == "daily",
        where: d.period_start > ^after_date and d.period_start <= ^until,
        order_by: d.period_start
    )
  end

  defp level1_start_date(thread, today) do
    case window_start(thread, :teacher, today) do
      nil -> nil
      %{inserted_at: inserted_at} -> Clock.to_taipei_date(inserted_at)
    end
  end

  defp render(%Digest{kind: "weekly"} = digest),
    do: "[#{digest.period_start} – #{digest.period_end}]\n#{digest.content}"

  defp render(%Digest{} = digest), do: "[#{digest.period_start}]\n#{digest.content}"

  # 00:00 Asia/Taipei on `date`, as a UTC instant.
  defp day_start(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-@taipei_offset_seconds, :second)
  end
end
```

- [ ] **Step 5: Run the test and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/assistant/memory_test.exs`
Expected: PASS (9 tests, 0 failures); compile clean.

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations lib/ganesha/assistant/digest.ex lib/ganesha/assistant/memory.ex lib/ganesha/assistant/message.ex test/ganesha/assistant/memory_test.exs
git commit -m "Add assistant digests and the Teacher chat's memory window and summaries"
```

---
### Task 13: `Conversation` — a 1:1 turn and a postback end to end; the worker becomes a router

**Files:**
- Create: `lib/ganesha/assistant/conversation.ex`
- Modify: `lib/ganesha/assistant.ex` (add `get_thread!/1`, `get_draft/1`, `get_drafts/1`, `append_to_last_reply/2`)
- Modify: `lib/ganesha/assistant/process_event_worker.ex` (rewrite)
- Modify: `lib/ganesha/line/client.ex` (`text_message/2`'s draft quick reply removed — Draft cards replace it), `lib/ganesha/line/client/mock.ex` (drop the `text_message` delegate; nothing calls `line_client().text_message` any more)
- Test: `test/ganesha/assistant/conversation_test.exs` (new); `test/ganesha/assistant/process_event_worker_test.exs` (rewrite — its reply, push-fallback, apology, quick-reply and postback tests pin the worker's old `send_reply`/`build_messages`/`resolve_postback` and move, rewritten, into `conversation_test.exs`); `test/ganesha/line/client_test.exs` (delete `test "text_message/2 attaches a confirm/discard quick reply for a draft id"`); `test/ganesha/line/client/mock_test.exs` (delete `test "text_message/1,2 delegates to Ganesha.Line.Client"`)

**Interfaces:**
- Consumes: `Agent.run/4` (Task 7), `Prompts.teacher/3`, `Prompts.student/1`, `Prompts.group/0`, `Prompts.snapshot_section/1`, `Snapshot.build/1` (Task 8), `Memory.history/3`, `Memory.summaries/2` (Task 12), `Tasks.for_chat/1` (Task 5), `Reply.build/3`, `Reply.history_text/3` (Task 11), `Cards.history_line/2`, `Labels.t/3` (Task 10), `Client.text_message/1`, `line_client().loading/2` (Task 9), `Assistant.confirm_draft/2`, `discard_draft/1`, `describe_draft/2` (Task 6).
- Produces:
  - `Ganesha.Assistant.Conversation.handle_message(thread, reply_token, source_id) :: :ok` — §6.1 steps 2–7 for a 1:1 thread whose latest user message is already stored.
  - `Ganesha.Assistant.Conversation.handle_postback(params :: map(), reply_token, source_id, teacher_id) :: :ok` — `set_locale`, and `confirm`/`discard` with the §6.3 outcome table plus the history line.
  - `Ganesha.Assistant.Conversation.run_turn(thread) :: {:ok, Turn.t()} | {:error, term()}` for `"teacher"` and `"user"` threads (prompt, memory and tasks per chat).
  - `Assistant.get_thread!(id)`, `Assistant.get_draft(id) :: Draft.t() | nil`, `Assistant.get_drafts([id]) :: [Draft.t()]` (in the order given), `Assistant.append_to_last_reply(thread, text) :: {:ok, Message.t()} | {:error, term()}`.
  - `Ganesha.Line.Client.text_message(text) :: map()` (arity 1 only).

- [ ] **Step 1: Write the failing tests**

`test/ganesha/assistant/conversation_test.exs`:

```elixir
defmodule Ganesha.Assistant.ConversationTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Clock, People, Sales, Studio}
  alias Ganesha.Assistant.{Conversation, Draft}
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Assistant.Tasks.{BookOneOff, RecordPayment}
  alias Ganesha.Line.Client.Mock, as: LineMock
  alias Ganesha.Sales.Payment

  @teacher "Uteacher0000000000000000000000"

  defmodule ExpiredTokenLine do
    @behaviour Ganesha.Line.ClientBehaviour
    def reply(_token, _messages), do: {:error, {400, %{"message" => "Invalid reply token"}}}
    def push(to, messages), do: LineMock.push(to, messages)
    def loading(chat_id, seconds), do: LineMock.loading(chat_id, seconds)
    def get_group_member(group_id, user_id), do: LineMock.get_group_member(group_id, user_id)
  end

  defmodule RejectingLine do
    @behaviour Ganesha.Line.ClientBehaviour

    def reply(_token, _messages),
      do:
        {:error, {400, %{"message" => "A message (messages[1]) in the request body is invalid"}}}

    def push(to, messages), do: LineMock.push(to, messages)
    def loading(chat_id, seconds), do: LineMock.loading(chat_id, seconds)
    def get_group_member(group_id, user_id), do: LineMock.get_group_member(group_id, user_id)
  end

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 400})

    %{thread: thread, student: student}
  end

  defp use_line(module) do
    Application.put_env(:ganesha, :line_client, module)
    on_exit(fn -> Application.put_env(:ganesha, :line_client, LineMock) end)
  end

  defp say(thread, text) do
    {:ok, _} = Assistant.append_message(thread, "user", text, nil)
    thread
  end

  # The model makes `calls` in its first round, then answers `final`.
  defp model(calls, final) do
    Mock.stub(fn messages, tools, opts ->
      Process.put(:last_request, %{messages: messages, tools: tools, system: opts[:system]})

      if calls == [] or Enum.any?(messages, &(&1.role == "tool")),
        do: {:ok, %{text: final, tool_calls: []}},
        else: {:ok, %{text: nil, tool_calls: calls}}
    end)
  end

  defp record_payment_call(student) do
    %{
      id: "t1",
      name: "record_payment",
      input: %{"student_id" => student.id, "amount" => 400, "method" => "cash"}
    }
  end

  defp payment_draft(thread, student, overrides \\ %{}) do
    {:ok, %{parsed: parsed}} =
      RecordPayment.propose(
        %{"student_id" => student.id, "amount" => 400, "method" => "cash"},
        %{thread: thread, locale: "zh-TW", today: Clock.today()}
      )

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "record_payment",
        student_id: student.id,
        parsed: Map.merge(parsed, overrides)
      })

    draft
  end

  defp postback(action, id), do: %{"action" => action, "draft_id" => to_string(id)}

  defp last_message(thread), do: thread |> Assistant.list_messages() |> List.last()

  describe "handle_message/3" do
    test "shows the loading animation, replies with the text and a Draft carousel, and records the card",
         %{thread: thread, student: student} do
      model([record_payment_call(student)], "已建立草稿，請確認。")

      assert :ok = Conversation.handle_message(say(thread, "Lulu 付了 400 現金"), "rt-1", @teacher)

      [draft] = Repo.all(Draft)

      assert [{:loading, {@teacher, 20}}, {:reply, {"rt-1", [text, flex]}}] = LineMock.calls()
      assert text == %{type: "text", text: "已建立草稿，請確認。"}
      assert %{type: "flex", contents: %{type: "carousel", contents: [bubble]}} = flex

      assert Enum.any?(
               bubble.footer.contents,
               &(&1.action[:data] == "action=confirm&draft_id=#{draft.id}")
             )

      assert last_message(thread).content ==
               "已建立草稿，請確認。\n[草稿 ##{draft.id} 待確認] 收款 Lulu NT$400"
    end

    test "gives the model the snapshot, the Teacher chat's tasks and her history", %{
      thread: thread,
      student: student
    } do
      model([], "好")

      :ok = Conversation.handle_message(say(thread, "嗨"), "rt-1", @teacher)

      request = Process.get(:last_request)
      assert request.system =~ "- student #{student.id}: Lulu"

      assert Enum.map(request.tools, & &1.name) ==
               ~w(record_payment book_one_off makeup_request ask_teacher set_language)

      assert [%{role: "user", content: "嗨"}] = request.messages
    end

    test "a Student chat gets only set_language and no snapshot" do
      {:ok, stranger} = Assistant.get_or_create_thread("user", "Ustranger")
      {:ok, stranger} = Assistant.set_locale(stranger, "en")
      model([], "Hello!")

      :ok = Conversation.handle_message(say(stranger, "hi"), "rt-2", "Ustranger")

      request = Process.get(:last_request)
      assert Enum.map(request.tools, & &1.name) == ["set_language"]
      refute request.system =~ "Studio snapshot"
      assert [{:loading, _}, {:reply, {"rt-2", [%{text: "Hello!"}]}}] = LineMock.calls()
    end

    test "after set_language the cards come back in the new language", %{thread: thread} do
      model(
        [
          %{id: "t1", name: "set_language", input: %{"locale" => "en"}},
          %{id: "t2", name: "makeup_request", input: %{"note" => "8/17"}}
        ],
        "Switched."
      )

      :ok = Conversation.handle_message(say(thread, "English please"), "rt-1", @teacher)

      assert [{:loading, _}, {:reply, {"rt-1", [_text, flex]}}] = LineMock.calls()
      [bubble] = flex.contents.contents
      assert Enum.map(bubble.footer.contents, & &1.action.label) == ["Confirm", "Discard"]
    end

    test "ask_teacher's options ride on the reply as quick replies", %{thread: thread} do
      model(
        [
          %{
            id: "t1",
            name: "ask_teacher",
            input: %{"question" => "哪一位？", "options" => ["Amy 王", "Amy 李"]}
          }
        ],
        "哪一位 Amy？"
      )

      :ok = Conversation.handle_message(say(thread, "Amy 付了"), "rt-1", @teacher)

      assert [{:loading, _}, {:reply, {"rt-1", [message]}}] = LineMock.calls()
      assert message.text == "哪一位 Amy？"
      assert Enum.map(message.quickReply.items, & &1.action.text) == ["Amy 王", "Amy 李"]
    end

    test "pushes the same messages when the reply token is no longer valid", %{thread: thread} do
      use_line(ExpiredTokenLine)
      model([], "好的")

      :ok = Conversation.handle_message(say(thread, "嗨"), "rt-1", @teacher)

      assert [{:loading, _}, {:push, {@teacher, [%{type: "text", text: "好的"}]}}] =
               LineMock.calls()
    end

    @tag :capture_log
    test "pushes a text-only version when LINE rejects the messages themselves", %{
      thread: thread,
      student: student
    } do
      use_line(RejectingLine)
      model([record_payment_call(student)], "已建立草稿。")

      :ok = Conversation.handle_message(say(thread, "Lulu 付了 400"), "rt-1", @teacher)

      [draft] = Repo.all(Draft)

      assert [{:loading, _}, {:push, {@teacher, [%{type: "text", text: text}]}}] =
               LineMock.calls()

      assert text == "已建立草稿。\n[草稿 ##{draft.id} 待確認] 收款 Lulu NT$400"
    end

    @tag :capture_log
    test "apologizes in the chat's language when the agent fails", %{thread: thread} do
      {:ok, thread} = Assistant.set_locale(thread, "en")
      Mock.stub(fn _messages, _tools, _opts -> {:error, :max_iterations_exceeded} end)

      assert :ok = Conversation.handle_message(say(thread, "hi"), "rt-1", @teacher)

      assert [
               {:loading, _},
               {:reply,
                {"rt-1",
                 [%{text: "Sorry, I couldn't process that message. Please try again later."}]}}
             ] = LineMock.calls()

      assert [%{role: "user"}] = Assistant.list_messages(thread)
    end
  end

  describe "handle_postback/4" do
    test "Confirm applies the Draft, says so, and tells the model", %{
      thread: thread,
      student: student
    } do
      draft = payment_draft(thread, student)

      assert :ok =
               Conversation.handle_postback(
                 postback("confirm", draft.id),
                 "rt-p",
                 @teacher,
                 @teacher
               )

      assert Repo.reload!(draft).state == "applied"

      assert [{:reply, {"rt-p", [%{type: "text", text: "已確認：收款 Lulu NT$400"}]}}] =
               LineMock.calls()

      assert last_message(thread).content == "[已確認] 草稿 ##{draft.id} 收款 Lulu NT$400"
    end

    test "a Draft that no longer applies is marked failed with the reason", %{
      thread: thread,
      student: student
    } do
      draft = payment_draft(thread, student, %{"purchase_id" => nil})

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher, @teacher)

      assert Repo.reload!(draft).state == "failed"

      assert [{:reply, {"rt-p", [%{text: "無法套用：收款 Lulu NT$400（missing_purchase_id）"}]}}] =
               LineMock.calls()

      assert last_message(thread).content ==
               "[無法套用] 草稿 ##{draft.id} 收款 Lulu NT$400 — missing_purchase_id"
    end

    test "Discard discards the Draft", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("discard", draft.id), "rt-p", @teacher, @teacher)

      assert Repo.reload!(draft).state == "discarded"
      assert [{:reply, {"rt-p", [%{text: "已捨棄：收款 Lulu NT$400"}]}}] = LineMock.calls()
    end

    test "a second tap says the Draft was already handled", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher, @teacher)

      Process.delete(:line_client_mock_calls)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-q", @teacher, @teacher)

      assert [{:reply, {"rt-q", [%{text: "這筆草稿已經處理過了。"}]}}] = LineMock.calls()
      assert Repo.aggregate(Payment, :count) == 1
    end

    test "a replaced Draft says so", %{thread: thread, student: student} do
      old = payment_draft(thread, student)

      {:ok, _} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "x"}},
          replaces: old.id
        )

      :ok = Conversation.handle_postback(postback("confirm", old.id), "rt-p", @teacher, @teacher)

      assert [{:reply, {"rt-p", [%{text: "這筆草稿已被取代。"}]}}] = LineMock.calls()
    end

    test "an unknown Draft id" do
      :ok = Conversation.handle_postback(postback("confirm", 999_999), "rt-p", @teacher, @teacher)
      :ok = Conversation.handle_postback(postback("discard", "abc"), "rt-q", @teacher, @teacher)

      assert [
               {:reply, {"rt-p", [%{text: "找不到這筆草稿。"}]}},
               {:reply, {"rt-q", [%{text: "找不到這筆草稿。"}]}}
             ] = LineMock.calls()
    end

    @tag :capture_log
    test "an exception leaves the Draft pending and asks her to try again", %{thread: thread} do
      {:ok, amy} = People.create_student(%{display_name: "Amy"})

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

      {:ok, trial} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 300})

      {:ok, %{parsed: parsed}} =
        BookOneOff.propose(
          %{"student_id" => amy.id, "session_id" => session.id, "package_id" => trial.id},
          %{thread: thread, locale: "zh-TW", today: Clock.today()}
        )

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "book_one_off",
          student_id: amy.id,
          parsed: Map.put(parsed, "custom_amount", -5)
        })

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher, @teacher)

      assert Repo.reload!(draft).state == "pending"
      assert [{:reply, {"rt-p", [%{text: "記錄失敗，請稍後再試。"}]}}] = LineMock.calls()
      assert last_message(thread).content =~ "[確認失敗] 草稿 ##{draft.id}"
    end

    test "only the teacher may confirm", %{thread: thread, student: student} do
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-x", "Ustranger", @teacher)

      assert Repo.reload!(draft).state == "pending"
      assert [{:reply, {"rt-x", [%{text: "無法辨識的操作。"}]}}] = LineMock.calls()
    end

    test "outcomes follow the chat's language", %{thread: thread, student: student} do
      {:ok, thread} = Assistant.set_locale(thread, "en")
      draft = payment_draft(thread, student)

      :ok =
        Conversation.handle_postback(postback("confirm", draft.id), "rt-p", @teacher, @teacher)

      assert [{:reply, {"rt-p", [%{text: "Confirmed: Payment Lulu NT$400"}]}}] = LineMock.calls()
      assert last_message(thread).content == "[Confirmed] Draft ##{draft.id} Payment Lulu NT$400"
    end

    test "choosing a language with nothing waiting welcomes the sender" do
      :ok =
        Conversation.handle_postback(
          %{"action" => "set_locale", "locale" => "en"},
          "rt-l",
          "Unew",
          @teacher
        )

      assert [{:reply, {"rt-l", [%{text: "Thanks! How can I help you today?"}]}}] =
               LineMock.calls()
    end
  end
end
```

Replace `test/ganesha/assistant/process_event_worker_test.exs` with:

```elixir
defmodule Ganesha.Assistant.ProcessEventWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Catalog, Line, People, Sales}
  alias Ganesha.Assistant.ProcessEventWorker
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Line.Client.Mock, as: LineMock

  @teacher "Uteacher0000000000000000000000"

  # Records a webhook event and runs its job inline; returns the job's result
  # and the stored event.
  defp deliver(event) do
    webhook_event_id = "evt-#{System.unique_integer([:positive])}"

    :ok =
      Line.record_event(
        Map.merge(%{"webhookEventId" => webhook_event_id, "mode" => "active"}, event)
      )

    line_event = Repo.get_by!(Line.LineEvent, webhook_event_id: webhook_event_id)
    {perform_job(ProcessEventWorker, %{"line_event_id" => line_event.id}), line_event}
  end

  defp new_line_message_id, do: "linemsg-#{System.unique_integer([:positive])}"

  defp text_from(user_id, text) do
    line_message_id = new_line_message_id()

    %{
      "type" => "message",
      "replyToken" => "rt-1",
      "source" => %{"type" => "user", "userId" => user_id},
      "message" => %{"id" => line_message_id, "type" => "text", "text" => text}
    }
  end

  defp group_text(sender_id, text, line_message_id \\ new_line_message_id()) do
    %{
      "type" => "message",
      "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => sender_id},
      "message" => %{"id" => line_message_id, "type" => "text", "text" => text}
    }
  end

  defp postback_from(user_id, data) do
    %{
      "type" => "postback",
      "replyToken" => "rt-p",
      "source" => %{"type" => "user", "userId" => user_id},
      "postback" => %{"data" => data}
    }
  end

  defp group_source(sender_id),
    do: %{"type" => "group", "groupId" => "Cabc", "userId" => sender_id}

  defp teacher_thread do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
    thread
  end

  defp lulu do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1200})

    student
  end

  defp payment_call(id, student, amount) do
    %{
      id: id,
      name: "record_payment",
      input: %{"student_id" => student.id, "amount" => amount, "method" => "line_pay"}
    }
  end

  describe "1:1 chats" do
    test "a teacher message runs a Conversation turn and marks the event processed" do
      thread = teacher_thread()
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "目前沒有人欠錢。", tool_calls: []}} end)

      assert {:ok, line_event} = deliver(text_from(@teacher, "誰欠錢？"))

      assert [
               {:loading, {@teacher, 20}},
               {:reply, {"rt-1", [%{type: "text", text: "目前沒有人欠錢。"}]}}
             ] = LineMock.calls()

      assert [%{content: "誰欠錢？"}, %{content: "目前沒有人欠錢。"}] = Assistant.list_messages(thread)
      assert Line.get_event!(line_event.id).processed_at
    end

    test "asks a new 1:1 sender to choose a language before running the agent" do
      assert {:ok, _} = deliver(text_from("Ustranger", "hi"))

      assert [{:reply, {"rt-1", [message]}}] = LineMock.calls()
      assert message.text =~ "Please choose your language"
      assert Enum.count(message.quickReply.items) == 2
    end

    test "choosing the language answers the message that was waiting" do
      {:ok, _} = deliver(text_from("Ustranger2", "hi"))
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "Hello!", tool_calls: []}} end)

      assert {:ok, _} = deliver(postback_from("Ustranger2", "action=set_locale&locale=en"))

      assert Enum.any?(LineMock.calls(), fn
               {:reply, {"rt-p", [%{type: "text", text: "Hello!"}]}} -> true
               _ -> false
             end)
    end

    test "a teacher postback is settled by the Conversation" do
      thread = teacher_thread()

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

      assert {:ok, _} = deliver(postback_from(@teacher, "action=confirm&draft_id=#{draft.id}"))

      assert Assistant.get_draft!(draft.id).state == "applied"
      assert [{:reply, {"rt-p", [%{text: "已確認：補課需求"}]}}] = LineMock.calls()
    end
  end

  describe "Group chat" do
    test "records a student's message and never calls LINE" do
      Mock.stub(fn _messages, _tools, _opts ->
        {:ok, %{text: "(internal reasoning, never sent)", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{role: "user", content: "2.Lulu （Line pay 1200元）"}, %{role: "assistant"}] =
               Assistant.list_messages(thread)
    end

    test "gives the model the Group chat's three tasks and the snapshot" do
      Mock.stub(fn _messages, tools, opts ->
        Process.put(:group_request, {Enum.map(tools, & &1.name), opts[:system]})
        {:ok, %{text: "nothing to do", tool_calls: []}}
      end)

      {:ok, _} = deliver(group_text("Ustudent1", "大家好"))

      {names, system} = Process.get(:group_request)
      assert names == ~w(record_payment book_one_off makeup_request)
      assert system =~ "Studio snapshot"
    end

    test "ignores the teacher's own posts in the group" do
      assert {:ok, _} = deliver(group_text(@teacher, "大家好"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert Assistant.list_messages(thread) == []
    end

    test "can produce a pending Draft, never an applied one" do
      student = lulu()
      Process.put(:round, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        round = Process.get(:round)
        Process.put(:round, round + 1)

        if round == 0,
          do: {:ok, %{text: nil, tool_calls: [payment_call("t1", student, 1200)]}},
          else: {:ok, %{text: "logged internally", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      assert LineMock.calls() == []

      assert [%Assistant.Draft{state: "pending", kind: "record_payment"}] =
               Repo.all(Assistant.Draft)
    end

    @tag :capture_log
    test "an agent failure returns :ok without retrying or duplicating the message" do
      Mock.stub(fn _messages, _tools, _opts -> {:error, :max_iterations_exceeded} end)

      assert {:ok, line_event} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert [%{role: "user"}] = Assistant.list_messages(thread)
      assert Line.get_event!(line_event.id).processed_at
    end
  end

  describe "unsend and messageEdited" do
    setup do
      student = lulu()
      Process.put(:round, 0)

      # Round 0 proposes 900; after an edit, round 2 proposes 1200.
      Mock.stub(fn _messages, _tools, _opts ->
        round = Process.get(:round)
        Process.put(:round, round + 1)

        case round do
          0 -> {:ok, %{text: nil, tool_calls: [payment_call("t1", student, 900)]}}
          2 -> {:ok, %{text: nil, tool_calls: [payment_call("t2", student, 1200)]}}
          _ -> {:ok, %{text: "logged", tool_calls: []}}
        end
      end)

      {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 900元）", "linemsg-1"))
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      [draft] = Repo.all(Assistant.Draft)
      %{thread: thread, draft: draft}
    end

    test "unsend clears the message's text and discards its pending Draft", c do
      assert {:ok, _} =
               deliver(%{
                 "type" => "unsend",
                 "source" => group_source("Ustudent1"),
                 "unsend" => %{"messageId" => "linemsg-1"}
               })

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert is_nil(user_message.content)
      assert Assistant.get_draft!(c.draft.id).state == "discarded"
    end

    test "messageEdited replaces the pending Draft with one from the corrected text", c do
      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => group_source("Ustudent1"),
                 "message" => %{"id" => "linemsg-1", "text" => "2.Lulu （Line pay 1200元）"}
               })

      assert Assistant.get_draft!(c.draft.id).state == "discarded"

      assert [%{parsed: %{"amount" => 1200}}] =
               Repo.all(from d in Assistant.Draft, where: d.state == "pending")

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end
  end
end
```

In `test/ganesha/line/client_test.exs`, delete `test "text_message/2 attaches a confirm/discard quick reply for a draft id"`. In `test/ganesha/line/client/mock_test.exs`, delete `test "text_message/1,2 delegates to Ganesha.Line.Client"` and the now-unused `alias Ganesha.Line.Client`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/assistant/conversation_test.exs test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL — `module Ganesha.Assistant.Conversation is not available`, and the worker tests fail on the missing `{:loading, …}` call and the old `已確認並記錄。` text.

- [ ] **Step 3: Add the Assistant helpers**

In `lib/ganesha/assistant.ex`, add after `get_or_create_thread/2`:

```elixir
  def get_thread!(id), do: Repo.get!(Thread, id)
```

Add after `get_draft!/1`:

```elixir
  def get_draft(id) when is_integer(id), do: Repo.get(Draft, id)

  @doc "The Drafts with these ids, in the order given."
  def get_drafts([]), do: []

  def get_drafts(ids) do
    by_id = Repo.all(from d in Draft, where: d.id in ^ids) |> Map.new(&{&1.id, &1})
    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end
```

Add after `append_message/5`:

```elixir
  @doc """
  Appends `text` to the thread's latest assistant reply (spec §6.1 step 7),
  so the model later sees which cards it sent.
  """
  def append_to_last_reply(%Thread{} = thread, text) when is_binary(text) do
    reply =
      Repo.one(
        from m in Message,
          where: m.thread_id == ^thread.id and m.role == "assistant" and is_nil(m.tool_calls),
          order_by: [desc: m.id],
          limit: 1
      )

    case reply do
      nil ->
        {:error, :no_reply}

      message ->
        content = Enum.join(Enum.reject([message.content, text], &(&1 in [nil, ""])), "\n")
        message |> Ecto.Changeset.change(content: content) |> Repo.update()
    end
  end
```

- [ ] **Step 4: Write `Conversation`**

`lib/ganesha/assistant/conversation.ex`:

```elixir
defmodule Ganesha.Assistant.Conversation do
  @moduledoc """
  One 1:1 turn and one postback, end to end (spec §6.1, §6.3), moved out of
  `Ganesha.Assistant.ProcessEventWorker`.

  A turn shows LINE's loading animation, runs the agent with the chat's
  prompt, memory and tasks, packs the `Turn` into LINE messages, replies
  (pushing when the reply token is unusable, or a text-only version when LINE
  rejects the messages), and appends the cards it sent to the model's own
  reply. Confirm and Discard answer with one text message and leave the
  outcome in the Teacher chat's history.
  """

  require Logger

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.{Agent, Memory, Prompts, Snapshot, Tasks, Thread, Turn}
  alias Ganesha.Line.{Cards, Client, Labels, Reply}

  @loading_seconds 20

  @spec handle_message(Thread.t(), String.t(), String.t()) :: :ok
  def handle_message(%Thread{} = thread, reply_token, source_id) do
    show_loading(source_id)

    case run_turn(thread) do
      {:ok, turn} ->
        # The turn may have changed the language (set_language).
        thread = Assistant.get_thread!(thread.id)
        locale = locale(thread)
        drafts = Assistant.get_drafts(turn.draft_ids)
        messages = Reply.build(turn, drafts, locale)

        deliver(reply_token, source_id, messages, fn -> text_only(turn, drafts, locale) end)
        record_cards(thread, Reply.history_text(turn, drafts, locale))

      {:error, reason} ->
        Logger.error(
          "Ganesha.Assistant.Agent.run/4 failed for thread #{thread.id}: #{inspect(reason)}"
        )

        apology = Client.text_message(Labels.t(:apology, locale(thread)))
        deliver(reply_token, source_id, [apology], nil)
    end

    :ok
  end

  @doc """
  Runs the agent for the thread's latest message with the prompt, history and
  tasks its chat gets (spec §6.1, §2 rule 7). Also used to re-run a turn after
  messageEdited.
  """
  @spec run_turn(Thread.t()) :: {:ok, Turn.t()} | {:error, term()}
  def run_turn(%Thread{source_type: "teacher"} = thread) do
    now = Clock.now()
    today = Clock.today(now)

    system =
      Prompts.teacher(locale(thread), Snapshot.build(today), Memory.summaries(thread, today))

    Agent.run(thread, Tasks.for_chat(:teacher), system, Memory.history(thread, :teacher, now))
  end

  def run_turn(%Thread{source_type: "user"} = thread) do
    Agent.run(
      thread,
      Tasks.for_chat(:student),
      Prompts.student(locale(thread)),
      Memory.history(thread, :student, Clock.now())
    )
  end

  @spec handle_postback(map(), String.t(), String.t(), String.t()) :: :ok
  def handle_postback(%{"action" => "set_locale"} = params, reply_token, source_id, teacher_id) do
    thread = user_thread(source_id, teacher_id)

    case Assistant.set_locale(thread, params["locale"]) do
      {:ok, thread} ->
        if pending_user_turn?(thread) do
          handle_message(thread, reply_token, source_id)
        else
          welcome = Client.text_message(Labels.t(:welcome, thread.locale))
          deliver(reply_token, source_id, [welcome], nil)
        end

      {:error, _reason} ->
        deliver(reply_token, source_id, [line_client().language_picker_message()], nil)
    end

    :ok
  end

  # Only the teacher may confirm or discard (spec §6.3).
  def handle_postback(%{"action" => action} = params, reply_token, source_id, teacher_id)
      when action in ["confirm", "discard"] and source_id == teacher_id do
    thread = user_thread(source_id, teacher_id)
    locale = locale(thread)
    {text, history_line} = settle(action, parse_id(params["draft_id"]), locale)

    deliver(reply_token, source_id, [Client.text_message(text)], nil)

    if history_line do
      {:ok, _} = Assistant.append_message(thread, "assistant", history_line, nil)
    end

    :ok
  end

  def handle_postback(_params, reply_token, source_id, teacher_id) do
    locale = source_id |> user_thread(teacher_id) |> locale()
    deliver(reply_token, source_id, [Client.text_message(Labels.t(:unknown_action, locale))], nil)
    :ok
  end

  defp settle(_action, nil, locale), do: {Labels.t(:not_found, locale), nil}

  defp settle(action, id, locale) do
    case Assistant.get_draft(id) do
      nil -> {Labels.t(:not_found, locale), nil}
      draft -> action |> outcome(draft) |> describe_outcome(locale)
    end
  end

  defp outcome("confirm", draft) do
    case Assistant.confirm_draft(draft, "line:teacher") do
      {:ok, applied} -> {:applied, applied}
      {:error, {:failed, failed}} -> {:failed, failed}
      {:error, :not_pending} -> not_pending(draft)
    end
  rescue
    exception ->
      Logger.error(
        "confirm_draft failed for draft #{draft.id}: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:exception, draft}
  end

  defp outcome("discard", draft) do
    case Assistant.discard_draft(draft) do
      {:ok, discarded} -> {:discarded, discarded}
      {:error, :not_pending} -> not_pending(draft)
    end
  end

  defp not_pending(draft) do
    current = Assistant.get_draft(draft.id)
    if current.state == "replaced", do: {:replaced, current}, else: {:already_handled, current}
  end

  defp describe_outcome({status, draft}, locale) do
    title = Assistant.describe_draft(draft, locale).title
    {outcome_text(status, draft, title, locale), history_line(status, draft, title, locale)}
  end

  defp outcome_text(:applied, _draft, title, locale),
    do: Labels.t(:confirmed, locale, title: title)

  defp outcome_text(:discarded, _draft, title, locale),
    do: Labels.t(:discarded, locale, title: title)

  defp outcome_text(:failed, draft, title, locale),
    do: Labels.t(:failed, locale, title: title, reason: draft.failure_reason)

  defp outcome_text(:already_handled, _draft, _title, locale),
    do: Labels.t(:already_handled, locale)

  defp outcome_text(:replaced, _draft, _title, locale), do: Labels.t(:replaced, locale)
  defp outcome_text(:exception, _draft, _title, locale), do: Labels.t(:exception, locale)

  # What the model reads next turn, e.g. "[已確認] 草稿 #41 收款 Amy NT$3,200".
  defp history_line(status, draft, title, locale) do
    line = "[#{Labels.t(tag(status), locale)}] #{Labels.t(:draft, locale)} ##{draft.id} #{title}"
    if status == :failed, do: "#{line} — #{draft.failure_reason}", else: line
  end

  defp tag(:applied), do: :tag_confirmed
  defp tag(:discarded), do: :tag_discarded
  defp tag(:failed), do: :tag_failed
  defp tag(:already_handled), do: :tag_already_handled
  defp tag(:replaced), do: :tag_replaced
  defp tag(:exception), do: :tag_exception

  defp parse_id(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_id(_raw), do: nil

  defp show_loading(source_id) do
    case line_client().loading(source_id, @loading_seconds) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("LINE loading animation failed: #{inspect(reason)}")
    end
  end

  # Reply first (free). An unusable reply token → push the same messages
  # (existing behaviour). LINE rejecting the messages themselves → log and
  # push a text-only version (spec §6.1 step 6, §7).
  defp deliver(_reply_token, _source_id, [], _fallback), do: :ok

  defp deliver(reply_token, source_id, messages, fallback) do
    case line_client().reply(reply_token, messages) do
      :ok ->
        :ok

      {:error, {400, body}} ->
        if reply_token_problem?(body) do
          push(source_id, messages)
        else
          Logger.error("LINE rejected the reply messages: #{inspect(body)}")
          push_text_only(source_id, fallback)
        end

      {:error, reason} ->
        Logger.warning("LINE reply failed (#{inspect(reason)}), falling back to push")
        push(source_id, messages)
    end
  end

  defp reply_token_problem?(%{"message" => message}) when is_binary(message),
    do: message =~ ~r/reply ?token/i

  defp reply_token_problem?(_body), do: false

  defp push_text_only(_source_id, nil), do: :ok

  defp push_text_only(source_id, fallback) do
    case fallback.() do
      "" -> :ok
      text -> push(source_id, [Client.text_message(text)])
    end
  end

  defp push(source_id, messages) do
    case line_client().push(source_id, messages) do
      :ok -> :ok
      {:error, reason} -> Logger.error("LINE push also failed: #{inspect(reason)}")
    end
  end

  # `turn.text` plus one line per Draft (spec §6.1 step 6).
  defp text_only(turn, drafts, locale) do
    [turn.text | Enum.map(drafts, &Cards.history_line({:draft, &1}, locale))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp record_cards(_thread, nil), do: :ok

  defp record_cards(thread, text) do
    case Assistant.append_to_last_reply(thread, text) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not record cards on thread #{thread.id}: #{inspect(reason)}")
    end
  end

  defp user_thread(source_id, teacher_id) do
    source_type = if source_id == teacher_id, do: "teacher", else: "user"
    {:ok, thread} = Assistant.get_or_create_thread(source_type, source_id)
    thread
  end

  defp pending_user_turn?(thread) do
    match?(%{role: "user"}, List.last(Assistant.list_messages(thread)))
  end

  defp locale(%Thread{locale: locale}), do: locale || "zh-TW"

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
```

- [ ] **Step 5: Slim the worker to routing**

Replace `lib/ganesha/assistant/process_event_worker.ex` with:

```elixir
defmodule Ganesha.Assistant.ProcessEventWorker do
  @moduledoc """
  Routes one `line_events` row (spec §6.1). 1:1 text messages go to
  `Ganesha.Assistant.Conversation` once the sender has picked a language (the
  first-contact picker lives here); 1:1 postbacks go to
  `Conversation.handle_postback/4`. Group chat messages run the agent with
  the Group chat's three tasks and are never answered. Unsend and
  messageEdited correct the stored text and discard the message's pending
  Drafts. A failed agent run is logged, never retried: a retry would
  re-append the message and risk duplicate Drafts for one fact.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Ganesha.{Assistant, Clock, Line, Repo}
  alias Ganesha.Assistant.{Agent, Conversation, Prompts, Snapshot, Tasks}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"line_event_id" => line_event_id}}) do
    line_event = Line.get_event!(line_event_id)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    :ok = route(line_event, teacher_id)
    Line.mark_processed(line_event)
    :ok
  end

  defp route(%{source_type: "user", raw_type: "message"} = event, teacher_id) do
    if simple_reply?(),
      do: handle_simple_reply(event),
      else: handle_user_message(event, teacher_id)
  end

  defp route(
         %{
           source_type: "user",
           raw_type: "postback",
           source_id: source_id,
           payload: %{"replyToken" => reply_token, "postback" => %{"data" => data}}
         },
         teacher_id
       ) do
    Conversation.handle_postback(URI.decode_query(data), reply_token, source_id, teacher_id)
  end

  defp route(
         %{source_type: "group", source_id: group_id, raw_type: "message"} = event,
         teacher_id
       ) do
    if get_in(event.payload, ["source", "userId"]) == teacher_id,
      do: :ok,
      else: handle_group_message(event, group_id)
  end

  defp route(%{raw_type: "unsend"} = event, _teacher_id), do: handle_unsend(event)
  defp route(%{raw_type: "messageEdited"} = event, _teacher_id), do: handle_message_edited(event)
  defp route(_event, _teacher_id), do: :ok

  defp handle_user_message(
         %{
           payload: %{
             "replyToken" => reply_token,
             "message" => %{"id" => line_message_id, "text" => text}
           },
           source_id: source_id
         },
         teacher_id
       ) do
    source_type = if source_id == teacher_id, do: "teacher", else: "user"
    {:ok, thread} = Assistant.get_or_create_thread(source_type, source_id)

    {:ok, _} =
      Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    if is_nil(thread.locale) do
      line_client().reply(reply_token, [line_client().language_picker_message()])
      :ok
    else
      Conversation.handle_message(thread, reply_token, source_id)
    end
  end

  defp handle_user_message(_event, _teacher_id), do: :ok

  defp handle_simple_reply(%{
         payload: %{"replyToken" => reply_token, "message" => %{"text" => text}},
         source_id: source_id
       }) do
    messages = [Line.Client.text_message("收到你的訊息：#{text}")]

    with {:error, reason} <- line_client().reply(reply_token, messages) do
      Logger.warning("line reply failed (#{inspect(reason)}), falling back to push")
      line_client().push(source_id, messages)
    end

    :ok
  end

  defp handle_simple_reply(_event), do: :ok

  # No `line_client()` call anywhere on this path: that absence, not a
  # runtime check, guarantees the Group chat never hears from the bot.
  defp handle_group_message(
         %{payload: %{"message" => %{"id" => line_message_id, "text" => text}}},
         group_id
       ) do
    {:ok, thread} = Assistant.get_or_create_thread("group", group_id)

    {:ok, _} =
      Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    thread |> run_group_agent() |> log_failure(thread, "group message")
  end

  defp handle_group_message(_event, _group_id), do: :ok

  # The Group chat's three tasks, the snapshot their ids come from, and its
  # full history; never summaries (ADR 0003).
  defp run_group_agent(thread) do
    system = Prompts.group() <> "\n\n" <> Prompts.snapshot_section(Snapshot.build(Clock.today()))
    Agent.run(thread, Tasks.for_chat(:group), system, Assistant.list_messages(thread))
  end

  defp handle_unsend(%{payload: %{"unsend" => %{"messageId" => line_message_id}}}) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: nil) |> Repo.update!()
        discard_pending_drafts_for(message)
        :ok
    end
  end

  defp handle_message_edited(%{
         payload: %{"message" => %{"id" => line_message_id, "text" => new_text}}
       }) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: new_text) |> Repo.update!()
        discard_pending_drafts_for(message)

        thread = Assistant.get_thread!(message.thread_id)

        result =
          if thread.source_type == "group",
            do: run_group_agent(thread),
            else: Conversation.run_turn(thread)

        log_failure(result, thread, "messageEdited")
    end
  end

  defp log_failure({:ok, _turn}, _thread, _what), do: :ok

  defp log_failure({:error, reason}, thread, what) do
    Logger.error(
      "Ganesha.Assistant.Agent.run/4 failed after #{what} for thread #{thread.id}: #{inspect(reason)}"
    )

    :ok
  end

  defp discard_pending_drafts_for(%Assistant.Message{id: id}) do
    from(d in Assistant.Draft, where: d.origin_message_id == ^id and d.state == "pending")
    |> Repo.all()
    |> Enum.each(&Assistant.discard_draft/1)
  end

  defp simple_reply? do
    Application.get_env(:ganesha, :line, [])
    |> Keyword.get(:simple_reply, false)
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
```

- [ ] **Step 6: Retire the draft quick reply from the LINE client**

In `lib/ganesha/line/client.ex`, replace

```elixir
  @doc "A plain text message, or one with a 確認/捨棄 quick reply for `draft_id`."
  def text_message(text, draft_id \\ nil)
  def text_message(text, nil), do: %{type: "text", text: text}

  def text_message(text, draft_id) when is_integer(draft_id) do
    %{
      type: "text",
      text: text,
      quickReply: %{
        items: [
          quick_reply_item("確認", "action=confirm&draft_id=#{draft_id}"),
          quick_reply_item("捨棄", "action=discard&draft_id=#{draft_id}")
        ]
      }
    }
  end
```

with

```elixir
  @doc "A plain text message. Drafts are confirmed from their Flex card (`Ganesha.Line.Cards`)."
  def text_message(text), do: %{type: "text", text: text}
```

(`quick_reply_item/2` stays; `language_picker_message/0` uses it.)

In `lib/ganesha/line/client/mock.ex`, delete the comment block above and the line `defdelegate text_message(text, draft_id \\ nil), to: Ganesha.Line.Client`.

- [ ] **Step 7: Run the tests and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/assistant test/ganesha/assistant_test.exs test/ganesha/line`
Expected: PASS (0 failures); compile clean.

- [ ] **Step 8: Commit**

```bash
git add lib/ganesha/assistant/conversation.ex lib/ganesha/assistant.ex lib/ganesha/assistant/process_event_worker.ex lib/ganesha/line/client.ex lib/ganesha/line/client/mock.ex test/ganesha/assistant/conversation_test.exs test/ganesha/assistant/process_event_worker_test.exs test/ganesha/line/client_test.exs test/ganesha/line/client/mock_test.exs
git commit -m "Extract Conversation: Draft cards, outcomes, loading, and memory-backed turns"
```

---
### Task 14: Digest writing — `write_missing_digests/2`, `invalidate_digests/2`, `DigestWorker`, invalidation on unsend/edit

**Files:**
- Create: `lib/ganesha/assistant/digest_worker.ex`
- Modify: `lib/ganesha/assistant/memory.ex` (add the write side), `lib/ganesha/assistant.ex` (add `list_threads/1`), `lib/ganesha/assistant/process_event_worker.ex` (invalidate on unsend/edit), `config/config.exs` (cron)
- Test: `test/ganesha/assistant/memory_test.exs` (two new `describe` blocks), `test/ganesha/assistant/digest_worker_test.exs` (new), `test/ganesha/assistant/process_event_worker_test.exs` (one new `describe` block)

**Interfaces:**
- Consumes: `Prompts.digest/1` (Task 8), `Digest` (Task 12), the configured `Ganesha.Assistant.Provider` (`complete(messages, [], system: …)`), `Conversation.run_turn/1` (Task 13, via the worker's edit path).
- Produces:
  - `Ganesha.Assistant.Memory.write_missing_digests(thread, today :: Date.t()) :: :ok` — a daily digest for each day from `today − 90` to `today − 1` with counted messages and none yet (input: one line per counted message, `"Teacher: …"` / `"Assistant: …"`), then a weekly digest for each complete Monday–Sunday week in range with daily digests and no weekly one (input: those dailies as `"[<date>]\n<content>"` joined by a blank line). Provider failures are logged and skipped.
  - `Ganesha.Assistant.Memory.invalidate_digests(thread_id, date :: Date.t()) :: :ok`.
  - `Ganesha.Assistant.DigestWorker` (Oban, `queue: :default`) — runs `write_missing_digests/2` for every `"teacher"` thread; one thread failing is logged and skipped.
  - `Assistant.list_threads(source_type :: String.t()) :: [Thread.t()]`.
  - Cron entry `{"30 16 * * *", Ganesha.Assistant.DigestWorker}`.

- [ ] **Step 1: Write the failing tests**

In `test/ganesha/assistant/memory_test.exs`, change `alias Ganesha.Assistant.{Digest, Memory}` to:

```elixir
  alias Ganesha.Assistant.{Digest, Memory, Prompts}
  alias Ganesha.Assistant.Provider.Mock
```

and add these two blocks before the module's final `end`:

```elixir
  describe "write_missing_digests/2" do
    setup do
      Process.put(:digest_inputs, [])

      Mock.stub(fn [%{role: "user", content: content}], [], opts ->
        Process.put(:digest_inputs, Process.get(:digest_inputs) ++ [{opts[:system], content}])

        if content =~ "fail-day",
          do: {:error, :overloaded},
          else: {:ok, %{text: "summary", tool_calls: []}}
      end)

      :ok
    end

    test "writes a daily digest for each past day with counted messages and none yet", %{
      thread: thread
    } do
      put(thread, "user", "9/29 的事", ~U[2026-09-29 04:00:00Z])
      put(thread, "user", "9/30 的事", ~U[2026-09-30 04:00:00Z])
      put(thread, "assistant", "好的", ~U[2026-09-30 04:01:00Z])
      put(thread, "user", "今天的事", @this_morning)
      digest(thread, "daily", ~D[2026-09-29], ~D[2026-09-29], "already written")

      assert :ok = Memory.write_missing_digests(thread, @today)

      assert [{system, transcript}] = Process.get(:digest_inputs)
      assert system == Prompts.digest("zh-TW")
      assert transcript == "Teacher: 9/30 的事\nAssistant: 好的"

      assert [~D[2026-09-29], ~D[2026-09-30]] =
               Repo.all(
                 from d in Digest,
                   where: d.kind == "daily",
                   order_by: d.period_start,
                   select: d.period_start
               )
    end

    test "skips today and days more than 90 days ago", %{thread: thread} do
      put(thread, "user", "太久以前", ~U[2026-07-03 04:00:00Z])
      put(thread, "user", "今天", @this_morning)

      assert :ok = Memory.write_missing_digests(thread, @today)
      assert Process.get(:digest_inputs) == []
    end

    test "writes a weekly digest from each complete week's daily digests", %{thread: thread} do
      digest(thread, "daily", ~D[2026-09-21], ~D[2026-09-21], "週一的事")
      digest(thread, "daily", ~D[2026-09-27], ~D[2026-09-27], "週日的事")
      digest(thread, "daily", ~D[2026-09-28], ~D[2026-09-28], "這週還沒過完")

      assert :ok = Memory.write_missing_digests(thread, @today)

      assert [{_system, input}] = Process.get(:digest_inputs)
      assert input == "[2026-09-21]\n週一的事\n\n[2026-09-27]\n週日的事"

      assert [%Digest{period_start: ~D[2026-09-21], period_end: ~D[2026-09-27]}] =
               Repo.all(from d in Digest, where: d.kind == "weekly")
    end

    @tag :capture_log
    test "a day that fails is skipped and the others are written", %{thread: thread} do
      put(thread, "user", "fail-day", ~U[2026-09-29 04:00:00Z])
      put(thread, "user", "正常的一天", ~U[2026-09-30 04:00:00Z])

      assert :ok = Memory.write_missing_digests(thread, @today)
      assert [~D[2026-09-30]] = Repo.all(from d in Digest, select: d.period_start)
    end
  end

  describe "invalidate_digests/2" do
    test "drops that day's daily digest and the weekly digest containing it", %{thread: thread} do
      digest(thread, "daily", ~D[2026-09-24], ~D[2026-09-24], "that day")
      digest(thread, "daily", ~D[2026-09-25], ~D[2026-09-25], "next day")
      digest(thread, "weekly", ~D[2026-09-21], ~D[2026-09-27], "that week")
      digest(thread, "weekly", ~D[2026-09-14], ~D[2026-09-20], "the week before")

      assert :ok = Memory.invalidate_digests(thread.id, ~D[2026-09-24])

      assert Repo.all(
               from d in Digest,
                 order_by: [d.kind, d.period_start],
                 select: {d.kind, d.period_start}
             ) == [{"daily", ~D[2026-09-25]}, {"weekly", ~D[2026-09-14]}]
    end
  end
```

`test/ganesha/assistant/digest_worker_test.exs`:

```elixir
defmodule Ganesha.Assistant.DigestWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.{Digest, DigestWorker}
  alias Ganesha.Assistant.Provider.Mock

  test "writes yesterday's digest for the Teacher chat and none for the Group chat" do
    # 12:00 Asia/Taipei yesterday.
    yesterday_noon = DateTime.new!(Date.add(Clock.today(), -1), ~T[04:00:00], "Etc/UTC")
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")

    for thread <- [teacher, group] do
      {:ok, message} = Assistant.append_message(thread, "user", "昨天的事", nil)
      message |> Ecto.Changeset.change(inserted_at: yesterday_noon) |> Repo.update!()
    end

    Mock.stub(fn _messages, [], _opts -> {:ok, %{text: "摘要", tool_calls: []}} end)

    assert :ok = perform_job(DigestWorker, %{})

    assert [%Digest{thread_id: thread_id, content: "摘要"}] =
             Repo.all(from d in Digest, where: d.kind == "daily")

    assert thread_id == teacher.id
    refute Repo.exists?(from d in Digest, where: d.thread_id == ^group.id)
  end
end
```

In `test/ganesha/assistant/process_event_worker_test.exs`, add `alias Ganesha.Assistant.Digest` to the alias list and this block before the module's final `end`:

```elixir
  describe "Teacher chat digests" do
    setup do
      thread = teacher_thread()

      {:ok, message} =
        Assistant.append_message(thread, "user", "原本的話", nil, line_message_id: "linemsg-t1")

      message |> Ecto.Changeset.change(inserted_at: ~U[2026-09-24 04:00:00Z]) |> Repo.update!()

      daily =
        Repo.insert!(%Digest{
          thread_id: thread.id,
          kind: "daily",
          period_start: ~D[2026-09-24],
          period_end: ~D[2026-09-24],
          content: "d"
        })

      weekly =
        Repo.insert!(%Digest{
          thread_id: thread.id,
          kind: "weekly",
          period_start: ~D[2026-09-21],
          period_end: ~D[2026-09-27],
          content: "w"
        })

      %{daily: daily, weekly: weekly}
    end

    test "unsending a message drops the digests covering its day", c do
      assert {:ok, _} =
               deliver(%{
                 "type" => "unsend",
                 "source" => %{"type" => "user", "userId" => @teacher},
                 "unsend" => %{"messageId" => "linemsg-t1"}
               })

      refute Repo.reload(c.daily)
      refute Repo.reload(c.weekly)
    end

    test "editing a message drops them too and re-runs the turn", c do
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "改好了", tool_calls: []}} end)

      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => %{"type" => "user", "userId" => @teacher},
                 "message" => %{"id" => "linemsg-t1", "text" => "改過的話"}
               })

      refute Repo.reload(c.daily)
      refute Repo.reload(c.weekly)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/ganesha/assistant/memory_test.exs test/ganesha/assistant/digest_worker_test.exs test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL — `Memory.write_missing_digests/2 is undefined or private`, `module Ganesha.Assistant.DigestWorker is not available`, and the two digest-invalidation tests find the digests still present.

- [ ] **Step 3: Add the write side to `Memory`**

In `lib/ganesha/assistant/memory.ex`:

1. Change the alias line to `alias Ganesha.Assistant.{Digest, Message, Prompts, Thread}` and add `require Logger` under `import Ecto.Query`.
2. Add to the `@moduledoc`, before the closing `"""`:

```
  - Writing (`DigestWorker`, nightly): a daily digest for every day in the
    last 90 days with counted messages and no digest, then a weekly digest
    for every complete week in range, built from that week's daily digests.
  - Invalidation: unsend or edit of a Teacher chat message deletes the daily
    digest for that date and the weekly digest containing it.
```

3. Add `@digest_days 90` under `@today_cap 100`.
4. Add these functions after `summaries/2`:

```elixir
  @spec write_missing_digests(Thread.t(), Date.t()) :: :ok
  def write_missing_digests(%Thread{} = thread, %Date{} = today) do
    first_day = Date.add(today, -@digest_days)
    last_day = Date.add(today, -1)
    locale = thread.locale || "zh-TW"

    written_days = digest_starts(thread, "daily", first_day)

    thread
    |> counted_by_day(first_day, today)
    |> Enum.reject(fn {day, _messages} -> MapSet.member?(written_days, day) end)
    |> Enum.each(fn {day, messages} ->
      write_digest(thread, locale, "daily", day, day, transcript(messages))
    end)

    written_weeks = digest_starts(thread, "weekly", first_day)

    first_day
    |> complete_weeks(last_day)
    |> Enum.reject(&MapSet.member?(written_weeks, &1))
    |> Enum.each(fn monday ->
      sunday = Date.add(monday, 6)

      case daily_texts(thread, monday, sunday) do
        [] ->
          :ok

        dailies ->
          write_digest(thread, locale, "weekly", monday, sunday, Enum.join(dailies, "\n\n"))
      end
    end)

    :ok
  end

  @spec invalidate_digests(integer(), Date.t()) :: :ok
  def invalidate_digests(thread_id, %Date{} = date) do
    Repo.delete_all(
      from d in Digest,
        where: d.thread_id == ^thread_id and d.kind == "daily" and d.period_start == ^date
    )

    Repo.delete_all(
      from d in Digest,
        where: d.thread_id == ^thread_id and d.kind == "weekly",
        where: d.period_start <= ^date and d.period_end >= ^date
    )

    :ok
  end
```

5. Add these private functions before `day_start/1`:

```elixir
  defp counted_by_day(thread, first_day, today) do
    Repo.all(
      from m in Message,
        where: m.thread_id == ^thread.id,
        where: m.role == "user" or (m.role == "assistant" and is_nil(m.tool_calls)),
        where: not is_nil(m.content),
        where: m.inserted_at >= ^day_start(first_day) and m.inserted_at < ^day_start(today),
        order_by: m.id
    )
    |> Enum.group_by(&Clock.to_taipei_date(&1.inserted_at))
    |> Enum.sort_by(fn {day, _messages} -> day end, Date)
  end

  defp transcript(messages) do
    Enum.map_join(messages, "\n", &"#{speaker(&1.role)}: #{&1.content}")
  end

  defp speaker("user"), do: "Teacher"
  defp speaker(_role), do: "Assistant"

  defp digest_starts(thread, kind, first_day) do
    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == ^kind and d.period_start >= ^first_day,
        select: d.period_start
    )
    |> MapSet.new()
  end

  # Mondays of the Monday–Sunday weeks lying wholly within [first_day, last_day].
  defp complete_weeks(first_day, last_day) do
    first_day
    |> Date.add(rem(8 - Date.day_of_week(first_day), 7))
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(Date.add(&1, 6), last_day) != :gt))
  end

  defp daily_texts(thread, from, to) do
    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == "daily",
        where: d.period_start >= ^from and d.period_start <= ^to,
        order_by: d.period_start,
        select: {d.period_start, d.content}
    )
    |> Enum.map(fn {day, content} -> "[#{day}]\n#{content}" end)
  end

  # Digests use the digest prompt and no tools (spec §6.4). A failure is
  # logged and skipped; the next night retries the gap (spec §7).
  defp write_digest(thread, locale, kind, period_start, period_end, text) do
    messages = [%{role: "user", content: text, tool_calls: []}]

    with {:ok, %{text: content}} when is_binary(content) and content != "" <-
           provider().complete(messages, [], system: Prompts.digest(locale)),
         {:ok, _digest} <-
           %Digest{}
           |> Digest.changeset(%{
             thread_id: thread.id,
             kind: kind,
             period_start: period_start,
             period_end: period_end,
             content: content
           })
           |> Repo.insert() do
      :ok
    else
      other ->
        Logger.warning(
          "#{kind} digest #{period_start} for thread #{thread.id} not written: #{inspect(other)}"
        )
    end
  end

  defp provider, do: Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider)
```

- [ ] **Step 4: Add `list_threads/1`, the worker, the cron entry and the invalidation hooks**

In `lib/ganesha/assistant.ex`, add after `get_thread!/1`:

```elixir
  def list_threads(source_type) do
    Repo.all(from t in Thread, where: t.source_type == ^source_type, order_by: t.id)
  end
```

`lib/ganesha/assistant/digest_worker.ex`:

```elixir
defmodule Ganesha.Assistant.DigestWorker do
  @moduledoc """
  Nightly at 00:30 Asia/Taipei (`30 16 * * *` UTC): fills every Teacher
  chat's missing daily and weekly digests (spec §6.4). One thread failing is
  logged and skipped; the next night fills the gap (spec §7). The Group chat
  and Student chats get no digests (ADR 0003).
  """
  use Oban.Worker, queue: :default

  require Logger

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Clock.today()

    for thread <- Assistant.list_threads("teacher") do
      try do
        Memory.write_missing_digests(thread, today)
      rescue
        exception ->
          Logger.error(
            "digests for thread #{thread.id} failed: " <>
              Exception.format(:error, exception, __STACKTRACE__)
          )
      end
    end

    :ok
  end
end
```

In `config/config.exs`, change the crontab to:

```elixir
     crontab: [
       {"10 16 * * *", Ganesha.Reporting.CloseMonthWorker},
       {"0 * * * *", Ganesha.Assistant.PurgeGroupRawTextWorker},
       {"30 16 * * *", Ganesha.Assistant.DigestWorker}
     ]}
```

In `lib/ganesha/assistant/process_event_worker.ex`:

1. Change `alias Ganesha.Assistant.{Agent, Conversation, Prompts, Snapshot, Tasks}` to `alias Ganesha.Assistant.{Agent, Conversation, Memory, Prompts, Snapshot, Tasks}`.
2. In `handle_unsend/1` and in `handle_message_edited/1`, add `forget_digests(message)` right after `discard_pending_drafts_for(message)`.
3. Add after `discard_pending_drafts_for/1`:

```elixir
  # Spec §6.4: an unsent or edited Teacher chat message invalidates the
  # digests covering its day; the next nightly run writes them again.
  defp forget_digests(%Assistant.Message{} = message) do
    thread = Assistant.get_thread!(message.thread_id)

    if thread.source_type == "teacher" do
      Memory.invalidate_digests(thread.id, Clock.to_taipei_date(message.inserted_at))
    end

    :ok
  end
```

- [ ] **Step 5: Run the tests and the compiler**

Run: `mix compile --warnings-as-errors && mix test test/ganesha/assistant`
Expected: PASS (0 failures); compile clean.

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/memory.ex lib/ganesha/assistant/digest_worker.ex lib/ganesha/assistant.ex lib/ganesha/assistant/process_event_worker.ex config/config.exs test/ganesha/assistant/memory_test.exs test/ganesha/assistant/digest_worker_test.exs test/ganesha/assistant/process_event_worker_test.exs
git commit -m "Write and invalidate Teacher chat digests nightly"
```

---
### Task 15: Offline smoke script on the new flow

**Files:**
- Modify: `priv/scripts/line_smoke.exs` (rewrite; Steps 3 and 5 pinned the old `propose_payment_draft` tool, the `payment` kind and the quick-reply confirm, and Step 3's `Enum.find_value` crashes on the new `{:loading, …}` call)

**Interfaces:**
- Consumes: everything from Tasks 1–14 through `ProcessEventWorker.perform/1`, `Provider.Mock`, `Line.Client.Mock`.
- Produces: `mix run priv/scripts/line_smoke.exs` prints `ALL CHECKS PASSED` against the dev database.

- [ ] **Step 1: Rewrite the script**

Replace `priv/scripts/line_smoke.exs` with:

```elixir
#!/usr/bin/env elixir
# Offline end-to-end smoke test for the LINE webhook + AI assistant.
#
#     mix ecto.migrate                        # once, applies the LINE tables to the dev DB
#     mix run priv/scripts/line_smoke.exs
#
# Needs no LINE channel, no Anthropic key and no network: the only two
# outbound edges (the LLM provider and the LINE Messaging API client) are
# swapped for the same in-process mocks the test suite uses. Everything
# between them — signature verification, webhook persistence, dedup, Oban
# dispatch, the Conversation, the agent loop over tasks, Draft creation, the
# Draft card, postback confirm and the retention sweep — is production code
# writing to the real dev DB.
#
# Rows created here are prefixed SMOKE / smoke- and deleted again at the end.

import Ecto.Query

alias Ganesha.{Catalog, Line, People, Repo, Sales}
alias Ganesha.Assistant

alias Ganesha.Assistant.{
  Digest,
  Draft,
  Message,
  ProcessEventWorker,
  PurgeGroupRawTextWorker,
  Thread
}

alias Ganesha.Assistant.Provider.Mock, as: ProviderMock
alias Ganesha.Line.Client.Mock, as: LineMock
alias Ganesha.Line.{LineEvent, VerifySignaturePlug}

teacher_id = "Usmoketeacher000000000000000"
group_id = "Csmokegroup00000000000000000"
secret = "smoke_channel_secret"

# Only the PASS/FAIL lines matter here; Ecto's debug SQL would bury them.
Logger.configure(level: :warning)

Application.put_env(:ganesha, :assistant, provider: ProviderMock)
Application.put_env(:ganesha, :line_client, LineMock)

Application.put_env(:ganesha, :line,
  channel_secret: secret,
  channel_access_token: "smoke_token",
  teacher_line_user_id: teacher_id
)

# Jobs must not run in a background queue process: the mocks live in this
# process's dictionary, and each step below runs the worker inline instead.
Oban.pause_all_queues()

defmodule Smoke do
  def init, do: Process.put(:smoke_failures, 0)

  def check(label, true), do: IO.puts([IO.ANSI.green(), "  PASS  ", IO.ANSI.reset(), label])

  def check(label, false) do
    Process.put(:smoke_failures, Process.get(:smoke_failures) + 1)
    IO.puts([IO.ANSI.red(), "  FAIL  ", IO.ANSI.reset(), label])
  end

  def check(label, other), do: check("#{label} (got: #{inspect(other)})", false)

  def step(n, title), do: IO.puts([IO.ANSI.bright(), "\nStep #{n}: #{title}", IO.ANSI.reset()])

  def failures, do: Process.get(:smoke_failures)
end

cleanup = fn ->
  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  smoke_event_ids =
    Repo.all(from e in LineEvent, where: like(e.webhook_event_id, "smoke-%"), select: e.id)

  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))

  thread_ids = from(t in Thread, where: t.source_id in ^[teacher_id, group_id], select: t.id)
  Repo.delete_all(from(d in Digest, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id in ^[teacher_id, group_id]))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(e in LineEvent, where: like(e.webhook_event_id, "smoke-%")))

  # Only the jobs this script's own events enqueued.
  Repo.delete_all(
    from(j in Oban.Job,
      where: j.worker == "Ganesha.Assistant.ProcessEventWorker",
      where: json_extract_path(j.args, ["line_event_id"]) in ^smoke_event_ids
    )
  )
end

Smoke.init()
cleanup.()

IO.puts([IO.ANSI.bright(), "LINE + AI assistant offline smoke test", IO.ANSI.reset()])

# ---------------------------------------------------------------- Step 1
Smoke.step(1, "webhook signature verification is fail-closed")

body = ~s({"events":[]})
valid_sig = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

conn = fn sig ->
  c =
    Plug.Test.conn(:post, "/line/webhook", body)
    |> Plug.Conn.assign(:raw_body, body)

  c = if sig, do: Plug.Conn.put_req_header(c, "x-line-signature", sig), else: c
  VerifySignaturePlug.call(c, [])
end

ok_conn = conn.(valid_sig)
Smoke.check("valid signature passes through", ok_conn.halted == false)

bad_conn = conn.(Base.encode64("wrong-signature-bytes-------"))
Smoke.check("forged signature -> 403 + halt", bad_conn.status == 403 and bad_conn.halted)

none_conn = conn.(nil)

Smoke.check(
  "missing signature header -> 403 + halt",
  none_conn.status == 403 and none_conn.halted
)

# ---------------------------------------------------------------- Step 2
Smoke.step(2, "webhook ingestion is idempotent and enqueues exactly once")

teacher_event = %{
  "webhookEventId" => "smoke-teacher-1",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-1",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-1", "type" => "text", "text" => "小美轉了 3200"}
}

jobs_before = Repo.aggregate(Oban.Job, :count)
:ok = Line.record_event(teacher_event)
:ok = Line.record_event(teacher_event)

stored = Repo.all(from e in LineEvent, where: e.webhook_event_id == "smoke-teacher-1")
Smoke.check("duplicate delivery stored exactly once", length(stored) == 1)
Smoke.check("teacher event source_id is the user", hd(stored).source_id == teacher_id)

jobs_after = Repo.aggregate(Oban.Job, :count)
Smoke.check("exactly one job enqueued for two deliveries", jobs_after - jobs_before == 1)

# ---------------------------------------------------------------- Step 3
Smoke.step(3, "teacher 1:1 turn: record_payment becomes a Draft, the reply carries its card")

{:ok, student} = People.create_student(%{display_name: "SMOKE 小美", active: true})

package =
  Repo.get_by(Catalog.Package, name: "月課程") ||
    (
      {:ok, p} =
        Catalog.create_package(%{
          name: "SMOKE 月課程",
          kind: "monthly",
          price_per_class: 400,
          included_makeups: 1
        })

      p
    )

{:ok, purchase} =
  Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 3200})

ProviderMock.stub(fn messages, _tools, _opts ->
  if Enum.any?(messages, &(&1.role == "tool")) do
    {:ok, %{text: "已建立一筆 3200 的收款草稿，請確認。", tool_calls: []}}
  else
    {:ok,
     %{
       text: nil,
       tool_calls: [
         %{
           id: "smoke-call-1",
           name: "record_payment",
           input: %{
             "student_id" => student.id,
             "purchase_id" => purchase.id,
             "amount" => 3200,
             "method" => "line_bank",
             "reported_last5" => "12345"
           }
         }
       ]
     }}
  end
end)

# A 1:1 thread without a locale gets the language picker instead of the agent;
# the teacher has already chosen hers.
{:ok, teacher_thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, _} = Assistant.set_locale(teacher_thread, "zh-TW")

teacher_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-1")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => teacher_line_event.id}})

teacher_thread = Repo.get_by!(Thread, source_type: "teacher", source_id: teacher_id)
teacher_messages = Assistant.list_messages(teacher_thread)

Smoke.check(
  "thread holds user + assistant + tool + final assistant turns",
  Enum.map(teacher_messages, & &1.role) == ["user", "assistant", "tool", "assistant"]
)

Smoke.check(
  "user message stamped with the LINE message id",
  hd(teacher_messages).line_message_id == "smoke-msg-1"
)

draft = Repo.one(from d in Draft, where: d.thread_id == ^teacher_thread.id)

Smoke.check(
  "pending record_payment draft created",
  draft && draft.kind == "record_payment" && draft.state == "pending"
)

Smoke.check(
  "draft linked to the originating message",
  draft && draft.origin_message_id == hd(teacher_messages).id
)

calls = LineMock.calls()
replies = for {:reply, {_token, messages}} <- calls, do: messages

Smoke.check(
  "loading animation shown before the reply",
  match?([{:loading, {^teacher_id, 20}} | _], calls)
)

Smoke.check("exactly one LINE reply sent to the teacher", length(replies) == 1)

carousel = replies |> List.first([]) |> Enum.find(&(&1[:type] == "flex"))
bubble = carousel && hd(carousel.contents.contents)

postback_data =
  bubble &&
    bubble.footer.contents
    |> Enum.map(& &1.action[:data])
    |> Enum.reject(&is_nil/1)

Smoke.check(
  "the reply carries this draft's card with 確認 / 捨棄",
  postback_data == ["action=confirm&draft_id=#{draft.id}", "action=discard&draft_id=#{draft.id}"]
)

Smoke.check(
  "the model's reply records the card it sent",
  List.last(teacher_messages).content =~ "[草稿 ##{draft.id} 待確認] 收款 SMOKE 小美 NT$3,200"
)

Smoke.check("event marked processed", Repo.reload!(teacher_line_event).processed_at != nil)

# ---------------------------------------------------------------- Step 4
Smoke.step(4, "group turn is listen-only: history recorded, nothing sent back")

group_event = %{
  "webhookEventId" => "smoke-group-1",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-2",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => "Usmokestudent000"},
  "message" => %{"id" => "smoke-msg-2", "type" => "text", "text" => "我這週三要請假"}
}

:ok = Line.record_event(group_event)
group_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-1")

Smoke.check(
  "group event source_id is the group, not the sender",
  group_line_event.source_id == group_id
)

ProviderMock.stub(fn _messages, _tools, _opts ->
  {:ok, %{text: "（僅記錄，無需建立草稿）", tool_calls: []}}
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => group_line_event.id}})

group_thread = Repo.get_by!(Thread, source_type: "group", source_id: group_id)
group_messages = Assistant.list_messages(group_thread)

Smoke.check(
  "group message recorded in the group thread",
  Enum.any?(group_messages, &(&1.content == "我這週三要請假"))
)

Smoke.check("NOTHING sent to LINE from the group path", LineMock.calls() == [])

# ---------------------------------------------------------------- Step 5
Smoke.step(5, "teacher postback is the only path that confirms money")

postback_event = %{
  "webhookEventId" => "smoke-postback-1",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-3",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{"data" => "action=confirm&draft_id=#{draft.id}"}
}

:ok = Line.record_event(postback_event)
postback_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-1")
Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => postback_line_event.id}})

payment = Repo.one(from p in Sales.Payment, where: p.purchase_id == ^purchase.id)
Smoke.check("payment row created from the draft", payment != nil)
Smoke.check("payment is confirmed", payment && payment.state == "confirmed")

Smoke.check(
  "confirmed_by records the human LINE action",
  payment && payment.confirmed_by == "line:teacher"
)

Smoke.check("payment tagged as draft-sourced", payment && payment.source == "line_draft")

Smoke.check(
  "amount and method came from the draft",
  payment && payment.amount == 3200 && payment.method == "line_bank"
)

applied = Repo.reload!(draft)
Smoke.check("draft marked applied", applied.state == "applied")

Smoke.check(
  "draft points at the payment row",
  applied.applied_record_type == "Ganesha.Sales.Payment" and
    applied.applied_record_id == payment.id
)

Smoke.check(
  "the teacher is told what was confirmed",
  (for {:reply, {_token, [message]}} <- LineMock.calls(), do: message.text) ==
    ["已確認：收款 SMOKE 小美 NT$3,200"]
)

Smoke.check(
  "the outcome is in the model's history",
  List.last(Assistant.list_messages(teacher_thread)).content ==
    "[已確認] 草稿 ##{draft.id} 收款 SMOKE 小美 NT$3,200"
)

replay = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => postback_line_event.id}})

payments_after =
  Repo.aggregate(from(p in Sales.Payment, where: p.purchase_id == ^purchase.id), :count)

Smoke.check(
  "replaying the same postback does not double-charge",
  replay == :ok and payments_after == 1
)

# ---------------------------------------------------------------- Step 6
Smoke.step(6, "24h retention sweep purges group raw text, keeps the teacher's")

old = DateTime.utc_now() |> DateTime.add(-25 * 3600, :second) |> DateTime.truncate(:second)

Repo.update_all(from(e in LineEvent, where: e.webhook_event_id == "smoke-group-1"),
  set: [inserted_at: old]
)

Repo.update_all(from(e in LineEvent, where: e.webhook_event_id == "smoke-teacher-1"),
  set: [inserted_at: old]
)

Repo.update_all(from(m in Message, where: m.thread_id == ^group_thread.id),
  set: [inserted_at: old]
)

Repo.update_all(from(m in Message, where: m.thread_id == ^teacher_thread.id),
  set: [inserted_at: old]
)

:ok = PurgeGroupRawTextWorker.perform(%Oban.Job{})

Smoke.check(
  "group event payload purged",
  Repo.reload!(group_line_event).payload == %{"purged" => true}
)

Smoke.check(
  "group message text nulled",
  Repo.all(from m in Message, where: m.thread_id == ^group_thread.id, select: m.content)
  |> Enum.all?(&is_nil/1)
)

Smoke.check(
  "teacher event payload retained",
  Repo.reload!(teacher_line_event).payload["webhookEventId"] == "smoke-teacher-1"
)

Smoke.check(
  "teacher thread text retained",
  Repo.all(
    from m in Message,
      where: m.thread_id == ^teacher_thread.id and m.role == "user",
      select: m.content
  ) == ["小美轉了 3200"]
)

Smoke.check(
  "confirmed draft's parsed data retained",
  Repo.reload!(draft).parsed["amount"] == 3200
)

# ---------------------------------------------------------------- teardown
cleanup.()
Oban.resume_all_queues()

IO.puts("")

case Smoke.failures() do
  0 ->
    IO.puts([
      IO.ANSI.green(),
      "ALL CHECKS PASSED",
      IO.ANSI.reset(),
      " — dev rows cleaned up, Oban queues resumed"
    ])

  n ->
    IO.puts([IO.ANSI.red(), "#{n} CHECK(S) FAILED", IO.ANSI.reset()])
    System.halt(1)
end
```

- [ ] **Step 2: Run it against the dev database**

Run: `mix ecto.create --quiet && mix ecto.migrate && mix run priv/scripts/line_smoke.exs`
Expected: every line `PASS`, ending with `ALL CHECKS PASSED — dev rows cleaned up, Oban queues resumed`; exit status 0.

- [ ] **Step 3: Commit**

```bash
git add priv/scripts/line_smoke.exs
git commit -m "Update the offline LINE smoke script to tasks, Draft cards and outcomes"
```

---

### Task 16: `mix precommit` and a real Sonnet 5.5 turn

**Files:**
- Create: `priv/scripts/line_real_turn.exs`

**Interfaces:**
- Consumes: `Conversation.run_turn/1`, `Assistant.get_drafts/1`, `Reply.build/3`, `Reply.history_text/3`, the dev `Provider.Anthropic` config (`ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` or `claude-sonnet-5-5`).
- Produces: `source .env.dev && mix run priv/scripts/line_real_turn.exs "<teacher message>"` prints the Turn, its Drafts, the LINE messages and the history line, then removes its rows.

- [ ] **Step 1: Write the script**

`priv/scripts/line_real_turn.exs`:

```elixir
#!/usr/bin/env elixir
# One real Teacher chat turn through Ganesha.Assistant.Conversation against
# the real model (spec §8: every slice ends with a real Sonnet 5.5 run).
#
#     mix ecto.migrate
#     source .env.dev && mix run priv/scripts/line_real_turn.exs "SMOKE 小美今天轉了 3200"
#
# Uses the dev Anthropic provider (ANTHROPIC_API_KEY; ANTHROPIC_MODEL or
# claude-sonnet-5-5) and Ganesha.Line.Client.Mock, so nothing reaches LINE.
# Prints the Turn, its Drafts, the LINE messages Reply.build/3 packs from it
# and the history line. Rows it creates are prefixed SMOKE and removed again.

import Ecto.Query

alias Ganesha.{Assistant, Catalog, People, Repo, Sales}
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

teacher_id = "Usmokerealturn00000000000000"
text = List.first(System.argv()) || "SMOKE 小美今天轉了 3200，是月課程的"

cleanup = fn ->
  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  thread_ids = from(t in Thread, where: t.source_id == ^teacher_id, select: t.id)

  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id == ^teacher_id))
  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))
end

cleanup.()

{:ok, student} = People.create_student(%{display_name: "SMOKE 小美"})

{:ok, package} =
  Catalog.create_package(%{
    name: "SMOKE 月課程",
    kind: "monthly",
    price_per_class: 400,
    included_makeups: 1
  })

{:ok, _purchase} =
  Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 3200})

{:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, thread} = Assistant.set_locale(thread, "zh-TW")
{:ok, _} = Assistant.append_message(thread, "user", text, nil)

IO.puts("Teacher: #{text}\n")

case Conversation.run_turn(thread) do
  {:ok, turn} ->
    drafts = Assistant.get_drafts(turn.draft_ids)

    IO.puts("== Turn")
    IO.inspect(turn, pretty: true)

    IO.puts("\n== Drafts")
    Enum.each(drafts, &IO.inspect(Map.take(&1, [:id, :kind, :state, :student_id, :parsed]), pretty: true))

    IO.puts("\n== LINE messages (Reply.build/3)")
    IO.puts(Jason.encode!(Reply.build(turn, drafts, "zh-TW"), pretty: true))

    IO.puts("\n== History line (Reply.history_text/3)")
    IO.puts(Reply.history_text(turn, drafts, "zh-TW") || "(none)")

    cleanup.()

  {:error, reason} ->
    cleanup.()
    IO.puts("Agent.run/4 failed: #{inspect(reason)}")
    System.halt(1)
end
```

- [ ] **Step 2: Run the whole quality gate**

Run: `mix precommit`
Expected: `compile --warnings-as-errors` clean, `deps.unlock --unused` no-op, `format` done, full `mix test` with 0 failures. If `format` rewrote files, they are included in Step 4's commit.

- [ ] **Step 3: Run one real turn**

Run: `mix ecto.create --quiet && mix ecto.migrate && source .env.dev && mix run priv/scripts/line_real_turn.exs "SMOKE 小美今天轉了 3200，是月課程的"`
Expected: `== Turn` shows a `%Ganesha.Assistant.Turn{}` with one id in `draft_ids` and text that says a Draft is waiting for confirmation (not that the payment was recorded); `== Drafts` shows `kind: "record_payment"`, `state: "pending"`, `parsed` with `"amount" => 3200`, `"student_name" => "SMOKE 小美"`, `"before_owed" => 3200`; `== LINE messages` is a JSON list with a `text` message and a `flex` message whose `contents.type` is `carousel` and whose footer buttons carry `action=confirm&draft_id=<id>` / `action=discard&draft_id=<id>`; `== History line` is `[草稿 #<id> 待確認] 收款 SMOKE 小美 NT$3,200`. If the model instead asks (non-empty `choices`), that is also correct behaviour — re-run with an unambiguous message to see the Draft path.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Add a real-model LINE turn script and pass precommit"
```

---

## Decisions this plan makes where the spec is silent

- `describe/2`'s `changes` tuple names its third element `after_value`: `after` is a reserved word and does not compile in a typespec.
- `Tasks.tool_schemas/1` returns atom-keyed maps (`name`, `description`, `input_schema`), the shape `Provider.Anthropic.to_wire_tool/1` already matches; the shared fields are added as `:replaces_draft_id` / `:show_card` properties.
- The Group chat's system prompt is `Prompts.group() <> "\n\n" <> Prompts.snapshot_section(snapshot)`: its three tasks take ids, and spec §2 rule 4 gives the snapshot "with every message". It still gets its full history and no summaries (ADR 0003). Group handling stays in `ProcessEventWorker`.
- `Labels.t/2` is the spec contract; `t/3` adds `%{name}` bindings for the outcome texts.
- The §6.3 outcome is appended to the Teacher chat for every outcome that has a Draft (not for "unknown id"); failed lines end with ` — <failure_reason>`, exceptions use the tag `確認失敗` / `Confirm failed`.
- `failure_reason` joins changeset errors with `"; "`.
- A Draft `kind` must name a `:change` task (a control tool's name is rejected).
- `Conversation.run_turn/1` is public: the worker's messageEdited re-run and `line_real_turn.exs` use it.
- `Reply.build/3` returns `[]` for an empty Turn and `Conversation` then sends nothing; choices with no other message get a `請選擇：` text to ride on.
- `Line.Client` treats any 2xx as success (LINE answers the loading endpoint with 202); a reply 400 whose `message` mentions the reply token counts as a token problem.
- A Draft replaced later in the same turn is dropped from `Turn.draft_ids`.
- `record_payment`: `student_id` required, `purchase_id` optional (the one purchase with money owed, else an error listing the candidates); `makeup_request`: `student_id` optional.
- Drafts migrated from `payment` confirm through `RecordPayment.apply/2` (missing `paid_on` → today; missing `purchase_id` → `failed` with `missing_purchase_id`).
- Daily digests cover days before today only; a weekly digest is written only for a complete Monday–Sunday week with at least one daily digest. "Within the last 14 days" means `period_start ≥ today − 14`.
- Non-raising getters added where a task must turn a bad id into a message: `People.get_student/1`, `Studio.get_session/1`, `Catalog.get_package/1`.
- Task 6 changes the soon-deleted `ProposePaymentDraft` to the `record_payment` kind and deletes `ProposeAttendanceDraft` one task early, so every task ends green.
