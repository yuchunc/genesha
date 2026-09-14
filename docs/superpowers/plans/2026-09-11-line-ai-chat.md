# LINE Chat Interface With AI Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a LINE Official Account that listens (never posts) in the teacher's student group and serves as a tool-calling AI assistant in her private 1:1 chat, both routed through one shared agent loop that can query ledger data and propose drafts she confirms via LINE postback.

**Architecture:** A signature-verified `/line/webhook` route persists every LINE event, then an Oban job runs `Ganesha.Assistant.Agent` — one tool-calling loop, one tool set, reused for both the group thread and the teacher's 1:1 thread. The group-thread code path never calls the LINE send API regardless of what the agent produces; the teacher-thread path replies with text and, when a draft was created, a confirm/discard quick reply. A tap posts back through the same webhook and applies (or discards) the draft via the existing `Sales`/`Roster` context functions — identical in effect to a human confirming in the app.

**Tech Stack:** Elixir ~> 1.17, Phoenix 1.8.13, Ecto + `ecto_sqlite3`, Oban (`Oban.Engines.Lite`, already configured), `:req` for both the LINE Messaging API and the Anthropic Messages API — no new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-11-line-ai-chat-design.md`

## Global Constraints

- No new deps: `:req` and `:jason` already in `mix.exs`, used for both external HTTP integrations.
- `Ganesha.Sales.Payment.confirmation_changeset/2` remains the only path to `state: "confirmed"` — no task may bypass `Sales.confirm_payment/2`.
- `/line/webhook` signature verification is scoped to that route only, never application-wide.
- The group thread must never call the LINE send API (reply/push), regardless of agent output — enforced structurally in the worker, not by a prompt.
- Group-thread raw text (`line_events.payload`, `assistant_messages.content`) purges at 24h; `drafts.parsed` and the teacher's own thread are exempt (spec §7).
- User-facing bot text is Traditional Chinese, studio vocabulary (堂數, 補課, 單堂, 體驗, 月課程), per `AGENTS.md` and the existing UI design system.
- Follow existing conventions throughout: schema/changeset/context shape (`lib/ganesha/sales/payment.ex`, `lib/ganesha/people.ex`), migration style (`priv/repo/migrations/20260907122702_create_monthly_closes.exs`), Oban worker + `Oban.Testing` pattern (`lib/ganesha/reporting/close_month_worker.ex`, `test/ganesha/reporting/close_month_worker_test.exs`), `Ganesha.DataCase`/inline test fixtures (no factory library).
- Run `mix ecto.gen.migration <name>` for every migration per `AGENTS.md`'s Ecto guideline, rather than hand-naming migration files.

---

## Task 1: `line_events` schema

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_line_events.exs`
- Create: `lib/ganesha/line/line_event.ex`
- Create: `lib/ganesha/line.ex`
- Test: `test/ganesha/line_test.exs`

**Interfaces:**
- Produces: `Ganesha.Line.LineEvent` schema (`webhook_event_id`, `source_type`, `source_id`, `raw_type`, `payload :map`, `processed_at`); `Ganesha.Line.record_event/1`, `Ganesha.Line.get_event!/1`, `Ganesha.Line.mark_processed/1`.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_line_events`

- [ ] **Step 2: Fill in the migration**

```elixir
defmodule Ganesha.Repo.Migrations.CreateLineEvents do
  use Ecto.Migration

  def change do
    create table(:line_events) do
      add :webhook_event_id, :string, null: false
      add :source_type, :string
      add :source_id, :string
      add :raw_type, :string, null: false
      add :payload, :map, null: false
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:line_events, [:webhook_event_id])
  end
end
```

- [ ] **Step 3: Write the failing test**

```elixir
defmodule Ganesha.LineTest do
  use Ganesha.DataCase
  alias Ganesha.Line

  # `mode: "standby"` here is deliberate: `record_event/1` only attempts to
  # enqueue `Ganesha.Assistant.ProcessEventWorker` for `mode: "active"`
  # events, and that worker does not exist until Task 15. Active-mode
  # enqueueing is exercised there instead, once it exists — see
  # `enqueue_teacher_message/1` in `process_event_worker_test.exs`.
  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "webhookEventId" => "01#{System.unique_integer([:positive])}",
        "type" => "message",
        "mode" => "standby",
        "source" => %{"type" => "user", "userId" => "Uteacher"},
        "message" => %{"type" => "text", "text" => "hi"}
      },
      overrides
    )
  end

  test "record_event/1 persists a new event" do
    assert :ok = Line.record_event(event())
  end

  test "record_event/1 is idempotent on webhook_event_id" do
    e = event()
    assert :ok = Line.record_event(e)
    assert :ok = Line.record_event(e)
    assert Repo.aggregate(Line.LineEvent, :count) == 1
  end

  test "get_event!/1 and mark_processed/1" do
    :ok = Line.record_event(event(%{"webhookEventId" => "mark-me"}))
    stored = Repo.get_by!(Line.LineEvent, webhook_event_id: "mark-me")

    loaded = Line.get_event!(stored.id)
    assert is_nil(loaded.processed_at)

    Line.mark_processed(loaded)
    assert %{processed_at: %DateTime{}} = Line.get_event!(stored.id)
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/ganesha/line_test.exs`
Expected: FAIL — `Ganesha.Line` is undefined.

- [ ] **Step 5: Implement the schema and context**

```elixir
defmodule Ganesha.Line.LineEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "line_events" do
    field :webhook_event_id, :string
    field :source_type, :string
    field :source_id, :string
    field :raw_type, :string
    field :payload, :map
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(line_event, attrs) do
    line_event
    |> cast(attrs, [:webhook_event_id, :source_type, :source_id, :raw_type, :payload])
    |> validate_required([:webhook_event_id, :raw_type, :payload])
    |> unique_constraint(:webhook_event_id)
  end
end
```

```elixir
defmodule Ganesha.Line do
  @moduledoc """
  Raw LINE webhook events: idempotent persistence and dispatch to
  `Ganesha.Assistant.ProcessEventWorker`. See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md §2, §3.
  """

  alias Ganesha.Line.LineEvent
  alias Ganesha.Repo

  @doc """
  Persists one webhook event, deduping on `webhookEventId`. Enqueues async
  processing only for a newly-inserted, active-mode event — a duplicate
  delivery or a standby-mode event is stored but never processed twice.
  """
  def record_event(%{"webhookEventId" => webhook_event_id} = event) do
    attrs = %{
      webhook_event_id: webhook_event_id,
      source_type: get_in(event, ["source", "type"]),
      source_id: source_id(event),
      raw_type: event["type"],
      payload: event
    }

    case %LineEvent{} |> LineEvent.changeset(attrs) |> Repo.insert() do
      {:ok, line_event} ->
        if event["mode"] == "active" do
          enqueue(line_event)
        end

        :ok

      {:error, changeset} ->
        if unique_violation?(changeset), do: :ok, else: {:error, changeset}
    end
  end

  def record_event(_event), do: :ok

  # The thing later code routes on: which *group* a group message belongs
  # to, or which *user* sent a 1:1 message — never the per-message sender
  # inside a group, which real LINE group payloads also carry as `userId`
  # alongside `groupId`. Picking `userId` unconditionally here would make
  # every group message's `source_id` the sender, not the group, and break
  # `Ganesha.Assistant.ProcessEventWorker`'s group-thread routing.
  defp source_id(%{"source" => %{"type" => "group", "groupId" => group_id}}), do: group_id
  defp source_id(%{"source" => %{"type" => "room", "roomId" => room_id}}), do: room_id
  defp source_id(%{"source" => %{"type" => "user", "userId" => user_id}}), do: user_id
  defp source_id(_event), do: nil


  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {:webhook_event_id, {_, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end

  defp enqueue(%LineEvent{id: id}) do
    %{"line_event_id" => id}
    |> Ganesha.Assistant.ProcessEventWorker.new()
    |> Oban.insert()
  end

  def get_event!(id), do: Repo.get!(LineEvent, id)

  def mark_processed(%LineEvent{} = event) do
    event
    |> Ecto.Changeset.change(processed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end
end
```

`Ganesha.Assistant.ProcessEventWorker` does not exist yet — `enqueue/1` will not compile-fail (Elixir resolves at call time), and none of this task's tests trigger it, since the `event/1` fixture defaults to `mode: "standby"`. Task 15 defines the worker and is where active-mode enqueueing is first exercised.

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/ganesha/line_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/ganesha/line.ex lib/ganesha/line/line_event.ex test/ganesha/line_test.exs
git commit -m "feat: add LineEvent, idempotent record_event/1"
```

---

## Task 2: `assistant_threads` schema

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_assistant_threads.exs`
- Create: `lib/ganesha/assistant/thread.ex`
- Create: `lib/ganesha/assistant.ex`
- Test: `test/ganesha/assistant_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `Ganesha.Assistant.Thread` (`source_type "group"|"teacher"`, `source_id`); `Ganesha.Assistant.get_or_create_thread/2`.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_assistant_threads`

- [ ] **Step 2: Fill in the migration**

```elixir
defmodule Ganesha.Repo.Migrations.CreateAssistantThreads do
  use Ecto.Migration

  def change do
    create table(:assistant_threads) do
      add :source_type, :string, null: false
      add :source_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assistant_threads, [:source_type, :source_id])
  end
end
```

- [ ] **Step 3: Write the failing test**

```elixir
defmodule Ganesha.AssistantTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant

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
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: FAIL — `Ganesha.Assistant` is undefined.

- [ ] **Step 5: Implement**

```elixir
defmodule Ganesha.Assistant.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @source_types ~w(group teacher)

  schema "assistant_threads" do
    field :source_type, :string
    field :source_id, :string

    timestamps(type: :utc_datetime)
  end

  def source_types, do: @source_types

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:source_type, :source_id])
    |> validate_required([:source_type, :source_id])
    |> validate_inclusion(:source_type, @source_types)
    |> unique_constraint([:source_type, :source_id],
      name: "assistant_threads_source_type_source_id_index"
    )
  end
end
```

```elixir
defmodule Ganesha.Assistant do
  @moduledoc """
  Threads, messages, and drafts for the LINE AI chat (group listening and
  the teacher's 1:1 assistant). See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Assistant.Thread
  alias Ganesha.Repo

  def get_or_create_thread(source_type, source_id) do
    case Repo.get_by(Thread, source_type: source_type, source_id: source_id) do
      %Thread{} = thread ->
        {:ok, thread}

      nil ->
        %Thread{} |> Thread.changeset(%{source_type: source_type, source_id: source_id}) |> Repo.insert()
    end
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/ganesha/assistant.ex lib/ganesha/assistant/thread.ex test/ganesha/assistant_test.exs
git commit -m "feat: add Assistant.Thread and get_or_create_thread/2"
```

---

## Task 3: `assistant_messages` schema

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_assistant_messages.exs`
- Create: `lib/ganesha/assistant/message.ex`
- Modify: `lib/ganesha/assistant.ex`
- Modify: `test/ganesha/assistant_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.Thread` (Task 2).
- Produces: `Ganesha.Assistant.Message` (`role "user"|"assistant"|"tool"`, `content`, `tool_calls {:array, :map}`, `line_message_id`); `Ganesha.Assistant.list_messages/1`, `Ganesha.Assistant.append_message/4`.

`line_message_id` is added now (unused until Task 19's unsend/edit handling) because it belongs on the row created at ingestion time, not bolted on later.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_assistant_messages`

- [ ] **Step 2: Fill in the migration**

```elixir
defmodule Ganesha.Repo.Migrations.CreateAssistantMessages do
  use Ecto.Migration

  def change do
    create table(:assistant_messages) do
      add :thread_id, references(:assistant_threads, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :string
      add :tool_calls, {:array, :map}
      # LINE's own message id, for unsend/messageEdited correlation (Task 19).
      # Only set for messages sourced directly from an inbound LINE text event.
      add :line_message_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:assistant_messages, [:thread_id])
    create unique_index(:assistant_messages, [:line_message_id])
  end
end
```

- [ ] **Step 3: Write the failing test**

Add to `test/ganesha/assistant_test.exs`:

```elixir
  test "append_message/4 and list_messages/1 round-trip in insertion order" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, _} = Assistant.append_message(thread, "user", "誰欠錢？", nil)
    {:ok, _} = Assistant.append_message(thread, "assistant", nil, [%{id: "t1", name: "student_balance", input: %{}}])

    assert [first, second] = Assistant.list_messages(thread)
    assert first.role == "user"
    assert first.content == "誰欠錢？"
    assert second.role == "assistant"
    assert [%{"id" => "t1", "name" => "student_balance"}] = second.tool_calls
  end

  test "append_message/4 rejects an unknown role" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert {:error, changeset} = Assistant.append_message(thread, "system", "x", nil)
    assert "is invalid" in errors_on(changeset).role
  end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: FAIL — `Assistant.append_message/4` undefined.

- [ ] **Step 5: Implement**

```elixir
defmodule Ganesha.Assistant.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.Thread

  @roles ~w(user assistant tool)

  schema "assistant_messages" do
    field :role, :string
    field :content, :string
    field :tool_calls, {:array, :map}
    field :line_message_id, :string

    belongs_to :thread, Thread

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:thread_id, :role, :content, :tool_calls, :line_message_id])
    |> validate_required([:thread_id, :role])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:thread_id)
    |> unique_constraint(:line_message_id)
  end
end
```

Add to `lib/ganesha/assistant.ex`:

```elixir
  alias Ganesha.Assistant.Message

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
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/ganesha/assistant.ex lib/ganesha/assistant/message.ex test/ganesha/assistant_test.exs
git commit -m "feat: add Assistant.Message, append_message/5 and list_messages/1"
```

---

## Task 4: `drafts` schema

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_drafts.exs`
- Create: `lib/ganesha/assistant/draft.ex`
- Modify: `lib/ganesha/assistant.ex`
- Modify: `test/ganesha/assistant_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.Thread`, `Ganesha.Assistant.Message` (Tasks 2–3); `Ganesha.People.Student`.
- Produces: `Ganesha.Assistant.Draft` (`kind`, `student_id`, `parsed :map`, `confidence`, `state`, `applied_record_type`, `applied_record_id`, `origin_message_id`); `Ganesha.Assistant.create_draft/2`, `Ganesha.Assistant.get_draft!/1`.

`origin_message_id` auto-stamps to the thread's latest `user` message at creation time — this is what Task 19's unsend/edit handling correlates a draft back to its triggering text, without changing the `Tool.call/2` contract.

- [ ] **Step 1: Generate the migration**

Run: `mix ecto.gen.migration create_drafts`

- [ ] **Step 2: Fill in the migration**

```elixir
defmodule Ganesha.Repo.Migrations.CreateDrafts do
  use Ecto.Migration

  def change do
    create table(:drafts) do
      add :thread_id, references(:assistant_threads, on_delete: :delete_all), null: false
      add :origin_message_id, references(:assistant_messages, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :student_id, references(:students, on_delete: :nilify_all)
      add :parsed, :map, null: false
      add :confidence, :float, null: false, default: 1.0
      add :state, :string, null: false, default: "pending"
      add :applied_record_type, :string
      add :applied_record_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:drafts, [:thread_id, :state])
    create index(:drafts, [:origin_message_id])
  end
end
```

- [ ] **Step 3: Write the failing test**

Add to `test/ganesha/assistant_test.exs`:

```elixir
  test "create_draft/2 stamps the thread's latest user message as its origin" do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Assistant.append_message(thread, "user", "2.Lulu （Line pay 1200元）", nil)

    assert {:ok, draft} =
             Assistant.create_draft(thread, %{
               kind: "payment",
               parsed: %{"amount" => 1200, "method" => "line_pay"},
               confidence: 0.8
             })

    [origin] = Assistant.list_messages(thread)
    assert draft.origin_message_id == origin.id
    assert draft.state == "pending"
  end

  test "create_draft/2 rejects an unknown kind" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    assert {:error, changeset} =
             Assistant.create_draft(thread, %{kind: "bogus", parsed: %{}})

    assert "is invalid" in errors_on(changeset).kind
  end

  test "get_draft!/1 fetches by id" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})
    assert Assistant.get_draft!(draft.id).id == draft.id
  end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: FAIL — `Assistant.create_draft/2` undefined.

- [ ] **Step 5: Implement**

```elixir
defmodule Ganesha.Assistant.Draft do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.{Message, Thread}
  alias Ganesha.People.Student

  @kinds ~w(payment attendance makeup_request unknown)
  @states ~w(pending applied discarded)

  schema "drafts" do
    field :kind, :string
    field :parsed, :map
    field :confidence, :float, default: 1.0
    field :state, :string, default: "pending"
    field :applied_record_type, :string
    field :applied_record_id, :integer

    belongs_to :thread, Thread
    belongs_to :origin_message, Message
    belongs_to :student, Student

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def states, do: @states

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:thread_id, :origin_message_id, :kind, :student_id, :parsed, :confidence])
    |> validate_required([:thread_id, :kind, :parsed])
    |> validate_inclusion(:kind, @kinds)
    |> put_change(:state, "pending")
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:origin_message_id)
    |> foreign_key_constraint(:student_id)
  end

  @doc "The only path to `applied`; records which ledger row it produced, if any (spec §8)."
  def apply_changeset(draft, applied_record_type, applied_record_id) do
    change(draft, %{
      state: "applied",
      applied_record_type: applied_record_type,
      applied_record_id: applied_record_id
    })
  end

  def state_changeset(draft, state) when state in @states, do: change(draft, %{state: state})
end
```

Add to `lib/ganesha/assistant.ex`:

```elixir
  alias Ganesha.Assistant.Draft

  def create_draft(%Thread{} = thread, attrs) do
    origin = latest_user_message(thread)

    attrs
    |> Map.put(:thread_id, thread.id)
    |> Map.put(:origin_message_id, origin && origin.id)
    |> then(&(%Draft{} |> Draft.changeset(&1) |> Repo.insert()))
  end

  defp latest_user_message(%Thread{} = thread) do
    Repo.one(
      from m in Message,
        where: m.thread_id == ^thread.id and m.role == "user",
        order_by: [desc: m.id],
        limit: 1
    )
  end

  def get_draft!(id), do: Repo.get!(Draft, id)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/ganesha/assistant_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations lib/ganesha/assistant.ex lib/ganesha/assistant/draft.ex test/ganesha/assistant_test.exs
git commit -m "feat: add Assistant.Draft, create_draft/2, get_draft!/1"
```

---

## Task 5: raw body capture + signature verification plug

**Files:**
- Create: `lib/ganesha/line/raw_body_plug.ex`
- Create: `lib/ganesha/line/verify_signature_plug.ex`
- Modify: `lib/ganesha_web/endpoint.ex:46-49`
- Modify: `config/test.exs`
- Test: `test/ganesha/line/verify_signature_plug_test.exs`

**Interfaces:**
- Consumes: `Application.fetch_env!(:ganesha, :line)[:channel_secret]`.
- Produces: `Ganesha.Line.RawBodyPlug.read_body/2` (a `Plug.Parsers` `:body_reader`); `Ganesha.Line.VerifySignaturePlug` (a standard 2-arity Plug).

- [ ] **Step 1: Add test config for the LINE channel secret**

`config/test.exs` currently has no `:line` config. Add after the Oban line:

```elixir
config :ganesha, :line,
  channel_secret: "test_channel_secret",
  channel_access_token: "test_channel_access_token",
  teacher_line_user_id: "Uteacher0000000000000000000000"
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Ganesha.Line.VerifySignaturePlugTest do
  use ExUnit.Case, async: true

  alias Ganesha.Line.VerifySignaturePlug

  defp signed_conn(body, secret \\ "test_channel_secret") do
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

    Plug.Test.conn(:post, "/line/webhook", body)
    |> Plug.Conn.assign(:raw_body, body)
    |> Plug.Conn.put_req_header("x-line-signature", signature)
  end

  test "accepts a body whose signature matches the configured channel secret" do
    conn = signed_conn(~s({"events":[]}))
    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    refute result.halted
  end

  test "rejects a mutated body with 403 and an empty response" do
    conn =
      ~s({"events":[]})
      |> signed_conn()
      |> Plug.Conn.assign(:raw_body, ~s({"events":[{"tampered":true}]}))

    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    assert result.halted
    assert result.status == 403
    assert result.resp_body == ""
  end

  test "rejects a missing signature header" do
    conn = Plug.Test.conn(:post, "/line/webhook", "{}") |> Plug.Conn.assign(:raw_body, "{}")
    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    assert result.halted
    assert result.status == 403
  end

  test "rejects a signature computed with the wrong secret" do
    conn = signed_conn(~s({"events":[]}), "wrong_secret")
    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    assert result.halted
    assert result.status == 403
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/ganesha/line/verify_signature_plug_test.exs`
Expected: FAIL — `Ganesha.Line.VerifySignaturePlug` is undefined.

- [ ] **Step 4: Implement both plugs**

```elixir
defmodule Ganesha.Line.RawBodyPlug do
  @moduledoc """
  A `Plug.Parsers` `:body_reader` that caches the exact bytes read from the
  request into `conn.assigns.raw_body` before parsing consumes them, so
  `VerifySignaturePlug` can verify against the untouched body afterward.
  Configured endpoint-wide in `GaneshaWeb.Endpoint`, because `Plug.Parsers`
  itself runs once, before the router decides which route it is.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache(conn, body)}
      {:more, body, conn} -> {:more, body, cache(conn, body)}
    end
  end

  defp cache(conn, body) do
    Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
  end
end
```

```elixir
defmodule Ganesha.Line.VerifySignaturePlug do
  @moduledoc """
  Scoped to `/line/webhook` only, never application-wide. Verifies
  `x-line-signature` against `Base64(HMAC-SHA256(channel_secret, raw_body))`
  using the bytes `Ganesha.Line.RawBodyPlug` cached before `Plug.Parsers`
  consumed the body (spec §2, original design §5.1).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    channel_secret = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_secret)
    raw_body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("x-line-signature") |> List.first()

    if valid_signature?(channel_secret, raw_body, signature) do
      conn
    else
      conn |> send_resp(403, "") |> halt()
    end
  end

  defp valid_signature?(_secret, _body, nil), do: false

  defp valid_signature?(secret, body, signature) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, signature)
  end
end
```

- [ ] **Step 5: Wire `RawBodyPlug` into the endpoint**

`lib/ganesha_web/endpoint.ex:46-49` currently reads:

```elixir
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
```

Replace with:

```elixir
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {Ganesha.Line.RawBodyPlug, :read_body, []}
```

This caches `raw_body` for every request, not only `/line/webhook`; the overhead is one extra binary concat per request and is the standard Phoenix webhook-signature recipe.

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/ganesha/line/verify_signature_plug_test.exs`
Expected: PASS

- [ ] **Step 7: Run the full suite to confirm the endpoint change is inert elsewhere**

Run: `mix test`
Expected: PASS (no existing test depends on the old `body_reader` default)

- [ ] **Step 8: Commit**

```bash
git add lib/ganesha/line/raw_body_plug.ex lib/ganesha/line/verify_signature_plug.ex lib/ganesha_web/endpoint.ex config/test.exs test/ganesha/line/verify_signature_plug_test.exs
git commit -m "feat: verify LINE webhook signatures against the cached raw body"
```

---

## Task 6: webhook controller + router

**Files:**
- Create: `lib/ganesha_web/controllers/line_webhook_controller.ex`
- Modify: `lib/ganesha_web/router.ex:16-23`
- Test: `test/ganesha_web/controllers/line_webhook_controller_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Line.record_event/1` (Task 1), `Ganesha.Line.VerifySignaturePlug` (Task 5).
- Produces: `POST /line/webhook`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule GaneshaWeb.LineWebhookControllerTest do
  use GaneshaWeb.ConnCase, async: true

  alias Ganesha.{Line, Repo}

  defp signed_post(conn, body) do
    secret = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_secret)
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-line-signature", signature)
    |> post("/line/webhook", body)
  end

  test "answers 200 for the empty connectivity probe", %{conn: conn} do
    conn = signed_post(conn, ~s({"events":[]}))
    assert conn.status == 200
  end

  test "persists a real event and answers 200", %{conn: conn} do
    # `mode: "standby"` — `Ganesha.Assistant.ProcessEventWorker` (Task 15)
    # does not exist yet, and `Line.record_event/1` only enqueues it for
    # active-mode events.
    body =
      Jason.encode!(%{
        "events" => [
          %{
            "webhookEventId" => "evt-1",
            "type" => "message",
            "mode" => "standby",
            "source" => %{"type" => "user", "userId" => "U1"},
            "replyToken" => "rt-1",
            "message" => %{"type" => "text", "text" => "hi"}
          }
        ]
      })

    conn = signed_post(conn, body)
    assert conn.status == 200
    assert Repo.get_by(Line.LineEvent, webhook_event_id: "evt-1")
  end

  test "rejects an unsigned request with 403", %{conn: conn} do
    conn = conn |> Plug.Conn.put_req_header("content-type", "application/json") |> post("/line/webhook", "{}")
    assert conn.status == 403
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha_web/controllers/line_webhook_controller_test.exs`
Expected: FAIL — no route for `/line/webhook`.

- [ ] **Step 3: Implement the controller**

```elixir
defmodule GaneshaWeb.LineWebhookController do
  use GaneshaWeb, :controller

  alias Ganesha.Line

  @doc """
  Verified upstream by `Ganesha.Line.VerifySignaturePlug`. Always answers
  200 once persisted — LINE redelivers on anything else (spec §2, original
  design §5.1, §5.7).
  """
  def create(conn, %{"events" => events}) do
    Enum.each(events, &Line.record_event/1)
    send_resp(conn, 200, "")
  end

  def create(conn, _params), do: send_resp(conn, 200, "")
end
```

- [ ] **Step 4: Wire the router**

`lib/ganesha_web/router.ex:16-23` currently reads:

```elixir
  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", GaneshaWeb do
  #   pipe_through :api
  # end
```

Replace with:

```elixir
  pipeline :api do
    plug :accepts, ["json"]
  end

  # Scoped to /line/webhook only — never application-wide (spec §2).
  pipeline :line_webhook do
    plug Ganesha.Line.VerifySignaturePlug
  end

  scope "/line", GaneshaWeb do
    pipe_through :line_webhook

    post "/webhook", LineWebhookController, :create
  end

  # Other scopes may use custom stacks.
  # scope "/api", GaneshaWeb do
  #   pipe_through :api
  # end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/ganesha_web/controllers/line_webhook_controller_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha_web/controllers/line_webhook_controller.ex lib/ganesha_web/router.ex test/ganesha_web/controllers/line_webhook_controller_test.exs
git commit -m "feat: wire POST /line/webhook behind signature verification"
```

---

## Task 7: `Ganesha.Assistant.Provider` behaviour + mock

**Files:**
- Create: `lib/ganesha/assistant/provider.ex`
- Create: `lib/ganesha/assistant/provider/mock.ex`
- Modify: `config/test.exs`
- Test: `test/ganesha/assistant/provider/mock_test.exs`

**Interfaces:**
- Produces: `@callback complete(messages :: [map()], tools :: [map()], opts :: keyword()) :: {:ok, %{text: String.t() | nil, tool_calls: [map()]}} | {:error, term()}`; `Ganesha.Assistant.Provider.Mock.stub/1`.

- [ ] **Step 1: Add test config for the default provider**

Add to `config/test.exs`:

```elixir
config :ganesha, :assistant, provider: Ganesha.Assistant.Provider.Mock
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Ganesha.Assistant.Provider.MockTest do
  use ExUnit.Case, async: true
  alias Ganesha.Assistant.Provider.Mock

  test "stub/1 controls what complete/3 returns" do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "hi", tool_calls: []}} end)
    assert {:ok, %{text: "hi", tool_calls: []}} = Mock.complete([], [], [])
  end

  test "complete/3 raises a clear error when no stub was registered" do
    assert_raise RuntimeError, ~r/stub\/1 was not called/, fn -> Mock.complete([], [], []) end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/ganesha/assistant/provider/mock_test.exs`
Expected: FAIL — `Ganesha.Assistant.Provider.Mock` is undefined.

- [ ] **Step 4: Implement**

```elixir
defmodule Ganesha.Assistant.Provider do
  @moduledoc """
  Swappable LLM backend for `Ganesha.Assistant.Agent`. `Ganesha.Assistant.Provider.Anthropic`
  is the production adapter (Task 13); `Ganesha.Assistant.Provider.Mock` is
  test-only. Configured via `config :ganesha, :assistant, provider: ...`.
  """

  @callback complete(messages :: [map()], tools :: [map()], opts :: keyword()) ::
              {:ok, %{text: String.t() | nil, tool_calls: [map()]}} | {:error, term()}
end
```

```elixir
defmodule Ganesha.Assistant.Provider.Mock do
  @moduledoc """
  Test-only `Ganesha.Assistant.Provider`. `Ganesha.Assistant.Agent` calls
  `complete/3` synchronously in the calling process (Oban's `perform_job/2`
  runs a worker's `perform/1` directly in the test process, same as
  `Ganesha.Reporting.CloseMonthWorkerTest`), so a process-dictionary stub is
  enough — no cross-process mocking needed.
  """
  @behaviour Ganesha.Assistant.Provider

  def stub(fun) when is_function(fun, 3), do: Process.put(:assistant_provider_mock_stub, fun)

  @impl true
  def complete(messages, tools, opts) do
    case Process.get(:assistant_provider_mock_stub) do
      nil -> raise "Ganesha.Assistant.Provider.Mock.stub/1 was not called before complete/3"
      fun -> fun.(messages, tools, opts)
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/ganesha/assistant/provider/mock_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/provider.ex lib/ganesha/assistant/provider/mock.ex config/test.exs test/ganesha/assistant/provider/mock_test.exs
git commit -m "feat: add Assistant.Provider behaviour and a test-only mock"
```

---

## Task 8: `Ganesha.Assistant.Tool` behaviour + `Agent` tool-calling loop

**Files:**
- Create: `lib/ganesha/assistant/tool.ex`
- Create: `lib/ganesha/assistant/agent.ex`
- Test: `test/ganesha/assistant/agent_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.Provider` (Task 7), `Ganesha.Assistant.{Thread, list_messages/1, append_message/4}` (Tasks 2–3).
- Produces: `@callback name/0`, `@callback schema/0`, `@callback call(input :: map(), thread :: Thread.t()) :: {String.t(), integer() | nil}`; `Ganesha.Assistant.Agent.run/3 :: {:ok, %{text: String.t(), draft_ids: [integer()]}} | {:error, term()}`.

The loop is capped at 6 iterations (spec §4.3 guardrail). A tool's `call/2` returns `{content_for_the_model, draft_id_or_nil}` — the second element is how the agent learns a draft was created, without the model having to say so itself.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ganesha.Assistant.AgentTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Agent
  alias Ganesha.Assistant.Provider.Mock

  defmodule EchoTool do
    @behaviour Ganesha.Assistant.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def schema, do: %{name: "echo", description: "echoes input", input_schema: %{}}

    @impl true
    def call(input, _thread), do: {"echoed: #{input["text"]}", nil}
  end

  defmodule DraftingTool do
    @behaviour Ganesha.Assistant.Tool

    @impl true
    def name, do: "draft_thing"

    @impl true
    def schema, do: %{name: "draft_thing", description: "creates a draft", input_schema: %{}}

    @impl true
    def call(_input, thread) do
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})
      {"draft created", draft.id}
    end
  end

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, _} = Assistant.append_message(thread, "user", "hello", nil)
    %{thread: thread}
  end

  test "returns the model's final text once it stops requesting tools", %{thread: thread} do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "hi there", tool_calls: []}} end)

    assert {:ok, %{text: "hi there", draft_ids: []}} = Agent.run(thread, [EchoTool], "system prompt")
    assert [_user, assistant] = Assistant.list_messages(thread)
    assert assistant.content == "hi there"
  end

  test "dispatches a tool call, feeds the result back, and returns any draft ids", %{thread: thread} do
    Process.put(:calls, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      case Process.get(:calls) do
        0 ->
          Process.put(:calls, 1)
          {:ok, %{text: nil, tool_calls: [%{id: "t1", name: "draft_thing", input: %{}}]}}

        1 ->
          {:ok, %{text: "done", tool_calls: []}}
      end
    end)

    assert {:ok, %{text: "done", draft_ids: [draft_id]}} = Agent.run(thread, [DraftingTool], "system prompt")
    assert Assistant.get_draft!(draft_id).state == "pending"
  end

  test "stops after the iteration cap rather than looping forever", %{thread: thread} do
    Mock.stub(fn _messages, _tools, _opts ->
      {:ok, %{text: nil, tool_calls: [%{id: "t", name: "echo", input: %{"text" => "x"}}]}}
    end)

    assert {:error, :max_iterations_exceeded} = Agent.run(thread, [EchoTool], "system prompt")
  end

  test "reports an unknown tool name without crashing", %{thread: thread} do
    Process.put(:calls, 0)

    Mock.stub(fn _messages, _tools, _opts ->
      case Process.get(:calls) do
        0 ->
          Process.put(:calls, 1)
          {:ok, %{text: nil, tool_calls: [%{id: "t1", name: "nonexistent", input: %{}}]}}

        1 ->
          {:ok, %{text: "ok", tool_calls: []}}
      end
    end)

    assert {:ok, %{text: "ok", draft_ids: []}} = Agent.run(thread, [EchoTool], "system prompt")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha/assistant/agent_test.exs`
Expected: FAIL — `Ganesha.Assistant.Agent` is undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Ganesha.Assistant.Tool do
  @moduledoc """
  A capability the agent loop can invoke. `call/2` returns `{content, draft_id}`:
  `content` is fed back to the model as the tool result; `draft_id` is the
  id of any `Ganesha.Assistant.Draft` the call created, or `nil` for a
  read-only tool.
  """

  @callback name() :: String.t()
  @callback schema() :: map()
  @callback call(input :: map(), thread :: Ganesha.Assistant.Thread.t()) ::
              {String.t(), integer() | nil}
end
```

```elixir
defmodule Ganesha.Assistant.Agent do
  @moduledoc """
  The tool-calling loop shared by both the group and teacher threads (spec
  §2, §4, §5). The same engine and tool set run for both; only the caller —
  `Ganesha.Assistant.ProcessEventWorker` — decides whether the loop's final
  text is ever sent anywhere.
  """

  alias Ganesha.Assistant

  @max_iterations 6

  @doc """
  Runs the agent to completion against `thread`, whose latest message is
  assumed already persisted by the caller. Returns `{:ok, %{text:,
  draft_ids:}}` once the model stops requesting tools, or `{:error,
  :max_iterations_exceeded}` if it never does.
  """
  def run(%Assistant.Thread{} = thread, tools, system_prompt) do
    provider = Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider)
    messages = thread |> Assistant.list_messages() |> Enum.map(&to_wire/1)
    schemas = Enum.map(tools, & &1.schema())

    loop(thread, provider, messages, schemas, tools, system_prompt, @max_iterations, [])
  end

  defp loop(_thread, _provider, _messages, _schemas, _tools, _system, 0, _draft_ids) do
    {:error, :max_iterations_exceeded}
  end

  defp loop(thread, provider, messages, schemas, tools, system, remaining, draft_ids) do
    case provider.complete(messages, schemas, system: system) do
      {:ok, %{text: text, tool_calls: []}} ->
        {:ok, _} = Assistant.append_message(thread, "assistant", text, nil)
        {:ok, %{text: text, draft_ids: Enum.reverse(draft_ids)}}

      {:ok, %{text: text, tool_calls: calls}} ->
        {:ok, _} = Assistant.append_message(thread, "assistant", text, calls)
        dispatched = Enum.map(calls, &dispatch(&1, tools, thread))
        results = Enum.map(dispatched, &elem(&1, 0))
        new_draft_ids = dispatched |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)
        {:ok, _} = Assistant.append_message(thread, "tool", nil, results)

        new_messages =
          messages ++
            [
              %{role: "assistant", content: text, tool_calls: calls},
              %{role: "tool", content: nil, tool_calls: results}
            ]

        # `new_draft_ids` is in call order; reversing it before prepending
        # keeps the whole accumulator in call order once the success clause
        # above does its one final `Enum.reverse/1` — prepending it
        # unreversed would come back backwards within this round.
        loop(
          thread,
          provider,
          new_messages,
          schemas,
          tools,
          system,
          remaining - 1,
          Enum.reverse(new_draft_ids) ++ draft_ids
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(%{id: id, name: name, input: input}, tools, thread) do
    {content, draft_id} =
      case Enum.find(tools, &(&1.name() == name)) do
        nil -> {"unknown tool: #{name}", nil}
        tool -> tool.call(input, thread)
      end

    {%{tool_use_id: id, content: content}, draft_id}
  end

  # Every wire message carries the same three keys regardless of whether it
  # came from memory (built inline above) or a DB reload — a message
  # missing `:tool_calls` would fail to match a Provider adapter's
  # `%{role: "assistant", content:, tool_calls:}` clause (e.g. the Anthropic
  # adapter, Task 13), which happens on every second `Agent.run/3` against
  # the same thread once the first run's final message is reloaded here.
  defp to_wire(%Assistant.Message{role: role, content: content, tool_calls: nil}) do
    %{role: role, content: content, tool_calls: []}
  end

  defp to_wire(%Assistant.Message{role: role, content: content, tool_calls: tool_calls}) do
    %{role: role, content: content, tool_calls: Enum.map(tool_calls, &atomize/1)}
  end

  # tool_calls round-trips through the {:array, :map} column as string keys;
  # the provider adapter and dispatch/1 above expect atom keys.
  defp atomize(map), do: for({k, v} <- map, into: %{}, do: {String.to_existing_atom(k), v})
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ganesha/assistant/agent_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tool.ex lib/ganesha/assistant/agent.ex test/ganesha/assistant/agent_test.exs
git commit -m "feat: add Assistant.Tool behaviour and the Agent tool-calling loop"
```

---

## Task 9: read tools — `FindStudent`, `StudentBalance`

**Files:**
- Create: `lib/ganesha/assistant/tools/find_student.ex`
- Create: `lib/ganesha/assistant/tools/student_balance.ex`
- Test: `test/ganesha/assistant/tools/find_student_test.exs`
- Test: `test/ganesha/assistant/tools/student_balance_test.exs`

**Interfaces:**
- Consumes: `Ganesha.People.{find_by_alias/1, list_students/0}`, `Ganesha.Reporting.outstanding_for_student/1`.
- Produces: two `Ganesha.Assistant.Tool` implementations.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Ganesha.Assistant.Tools.FindStudentTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.FindStudent
  alias Ganesha.People

  test "resolves an alias" do
    {:ok, student} = People.create_student(%{display_name: "莉芸"})
    {:ok, _} = People.add_alias(student, "Liyun")

    {content, draft_id} = FindStudent.call(%{"query" => "Liyun"}, nil)
    assert draft_id == nil
    assert %{"id" => id, "display_name" => "莉芸"} = Jason.decode!(content)
    assert id == student.id
  end

  test "falls back to an exact display name match" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {content, _} = FindStudent.call(%{"query" => "Lulu"}, nil)
    assert %{"id" => id} = Jason.decode!(content)
    assert id == student.id
  end

  test "reports no match" do
    {content, nil} = FindStudent.call(%{"query" => "nobody"}, nil)
    assert content == "no student found matching \"nobody\""
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.StudentBalanceTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.StudentBalance
  alias Ganesha.{Catalog, People, Sales}

  test "reports outstanding balance for a student" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, _} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

    {content, draft_id} = StudentBalance.call(%{"student_id" => student.id}, nil)
    assert draft_id == nil
    assert %{"student_id" => id, "outstanding" => 400} = Jason.decode!(content)
    assert id == student.id
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tools/find_student_test.exs test/ganesha/assistant/tools/student_balance_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Ganesha.Assistant.Tools.FindStudent do
  @moduledoc "Resolves a free-text name or alias to a student (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.People

  @impl true
  def name, do: "find_student"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Finds a student by display name or known alias.",
      input_schema: %{
        type: "object",
        properties: %{query: %{type: "string"}},
        required: ["query"]
      }
    }
  end

  @impl true
  def call(%{"query" => query}, _thread) do
    student =
      People.find_by_alias(query) ||
        Enum.find(People.list_students(), &(&1.display_name == query))

    case student do
      nil -> {"no student found matching #{inspect(query)}", nil}
      student -> {Jason.encode!(%{id: student.id, display_name: student.display_name, active: student.active}), nil}
    end
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.StudentBalance do
  @moduledoc "Reads a student's outstanding ledger balance (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.Reporting

  @impl true
  def name, do: "student_balance"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Returns how much a student currently owes the studio.",
      input_schema: %{
        type: "object",
        properties: %{student_id: %{type: "integer"}},
        required: ["student_id"]
      }
    }
  end

  @impl true
  def call(%{"student_id" => student_id}, _thread) do
    outstanding = Reporting.outstanding_for_student(student_id)
    {Jason.encode!(%{student_id: student_id, outstanding: outstanding}), nil}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tools/find_student_test.exs test/ganesha/assistant/tools/student_balance_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/tools/find_student.ex lib/ganesha/assistant/tools/student_balance.ex test/ganesha/assistant/tools/find_student_test.exs test/ganesha/assistant/tools/student_balance_test.exs
git commit -m "feat: add find_student and student_balance read tools"
```

---

## Task 10: read tools — `TodayRoster`, `UpcomingSessions`, `StudentHistory`

**Files:**
- Modify: `lib/ganesha/studio.ex` (add `sessions_between/2`)
- Create: `lib/ganesha/assistant/tools/today_roster.ex`
- Create: `lib/ganesha/assistant/tools/upcoming_sessions.ex`
- Create: `lib/ganesha/assistant/tools/student_history.ex`
- Test: `test/ganesha/studio_test.exs` (extend if present, else create)
- Test: `test/ganesha/assistant/tools/today_roster_test.exs`
- Test: `test/ganesha/assistant/tools/upcoming_sessions_test.exs`
- Test: `test/ganesha/assistant/tools/student_history_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Clock.today/0`, `Ganesha.Roster.{list_for_session/1, list_for_student/1}`, `Ganesha.Sales.list_purchases_for_student/1`.
- Produces: `Ganesha.Studio.sessions_between/2`; three `Ganesha.Assistant.Tool` implementations.

- [ ] **Step 1: Write the failing test for `Studio.sessions_between/2`**

```elixir
defmodule Ganesha.StudioTest do
  use Ganesha.DataCase
  alias Ganesha.Studio

  test "sessions_between/2 returns scheduled sessions within an inclusive date range" do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        default_style: "Hatha",
        label: "一 早晨"
      })

    {:ok, in_range} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-09-14], style: "Hatha"})
    {:ok, _out_of_range} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-09-21], style: "Hatha"})

    result = Studio.sessions_between(~D[2026-09-12], ~D[2026-09-18])
    assert [%{id: id}] = result
    assert id == in_range.id
  end
end
```

(If `test/ganesha/studio_test.exs` already exists with other tests, add this test to it instead of creating a new file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha/studio_test.exs`
Expected: FAIL — `Studio.sessions_between/2` undefined.

- [ ] **Step 3: Implement `sessions_between/2`**

Add to `lib/ganesha/studio.ex` after `next_session/0`:

```elixir
  @doc "Scheduled sessions with a date in the inclusive range `[from, to]`."
  def sessions_between(%Date{} = from, %Date{} = to) do
    Repo.all(
      from s in Session,
        left_join: slot in assoc(s, :slot),
        where: s.date >= ^from and s.date <= ^to and s.state == "scheduled",
        order_by: [asc: s.date, asc: fragment("coalesce(?, ?)", slot.start_time, s.start_time)],
        preload: [slot: slot]
    )
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ganesha/studio_test.exs`
Expected: PASS

- [ ] **Step 5: Write the failing tool tests**

```elixir
defmodule Ganesha.Assistant.Tools.TodayRosterTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.TodayRoster
  alias Ganesha.{Catalog, Clock, People, Roster, Sales, Studio}

  test "lists today's sessions with their roster" do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: Date.day_of_week(Clock.today()),
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        default_style: "Hatha",
        label: "今日班"
      })

    {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: Clock.today(), style: "Hatha"})
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, purchase} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})
    {:ok, _} = Roster.add_drop_in(session, student, purchase)

    {content, draft_id} = TodayRoster.call(%{}, nil)
    assert draft_id == nil
    assert [%{"roster" => [%{"student" => "Lulu"}]}] = Jason.decode!(content)
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.UpcomingSessionsTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.UpcomingSessions
  alias Ganesha.{Clock, Studio}

  test "lists sessions in the next N days" do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: Date.day_of_week(Date.add(Clock.today(), 2)),
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        default_style: "Hatha",
        label: "近日班"
      })

    {:ok, _} = Studio.create_session(%{slot_id: slot.id, date: Date.add(Clock.today(), 2), style: "Hatha"})

    {content, draft_id} = UpcomingSessions.call(%{"days" => 7}, nil)
    assert draft_id == nil
    assert [%{"style" => "Hatha"}] = Jason.decode!(content)
  end

  test "defaults to 7 days when no days argument is given" do
    {content, nil} = UpcomingSessions.call(%{}, nil)
    assert Jason.decode!(content) == []
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.StudentHistoryTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.StudentHistory
  alias Ganesha.{Catalog, People, Sales}

  test "summarizes a student's purchases" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, _} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

    {content, draft_id} = StudentHistory.call(%{"student_id" => student.id}, nil)
    assert draft_id == nil
    assert %{"purchases" => [%{"list_price" => 400}], "attendances" => []} = Jason.decode!(content)
  end
end
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tools/today_roster_test.exs test/ganesha/assistant/tools/upcoming_sessions_test.exs test/ganesha/assistant/tools/student_history_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 7: Implement**

```elixir
defmodule Ganesha.Assistant.Tools.TodayRoster do
  @moduledoc "Reads today's scheduled sessions and their roster (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Clock, Roster, Studio}

  @impl true
  def name, do: "today_roster"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Lists today's scheduled sessions with each session's roster.",
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def call(_input, _thread) do
    today = Clock.today()

    body =
      today
      |> Studio.sessions_between(today)
      |> Enum.map(fn session ->
        %{
          session_id: session.id,
          date: session.date,
          style: session.style,
          roster:
            session
            |> Roster.list_for_session()
            |> Enum.map(&%{student: &1.student.display_name, kind: &1.kind, state: &1.state})
        }
      end)

    {Jason.encode!(body), nil}
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.UpcomingSessions do
  @moduledoc "Reads scheduled sessions in the next N days, default 7 (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Clock, Studio}

  @impl true
  def name, do: "upcoming_sessions"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Lists scheduled sessions in the next N days (default 7).",
      input_schema: %{type: "object", properties: %{days: %{type: "integer"}}}
    }
  end

  @impl true
  def call(input, _thread) do
    days = Map.get(input, "days", 7)
    today = Clock.today()

    body =
      today
      |> Studio.sessions_between(Date.add(today, days))
      |> Enum.map(&%{session_id: &1.id, date: &1.date, style: &1.style})

    {Jason.encode!(body), nil}
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.StudentHistory do
  @moduledoc "Reads a student's purchase and attendance history (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Roster, Sales}

  @impl true
  def name, do: "student_history"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Returns a student's purchases and attendance history.",
      input_schema: %{
        type: "object",
        properties: %{student_id: %{type: "integer"}},
        required: ["student_id"]
      }
    }
  end

  @impl true
  def call(%{"student_id" => student_id}, _thread) do
    purchases =
      student_id
      |> Sales.list_purchases_for_student()
      |> Enum.map(&%{id: &1.id, list_price: &1.list_price, custom_amount: &1.custom_amount})

    attendances =
      student_id
      |> Roster.list_for_student()
      |> Enum.map(&%{session_id: &1.session_id, kind: &1.kind, state: &1.state})

    {Jason.encode!(%{purchases: purchases, attendances: attendances}), nil}
  end
end
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tools/today_roster_test.exs test/ganesha/assistant/tools/upcoming_sessions_test.exs test/ganesha/assistant/tools/student_history_test.exs`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/ganesha/studio.ex lib/ganesha/assistant/tools/today_roster.ex lib/ganesha/assistant/tools/upcoming_sessions.ex lib/ganesha/assistant/tools/student_history.ex test/ganesha/studio_test.exs test/ganesha/assistant/tools/today_roster_test.exs test/ganesha/assistant/tools/upcoming_sessions_test.exs test/ganesha/assistant/tools/student_history_test.exs
git commit -m "feat: add today_roster, upcoming_sessions, student_history read tools"
```

---

## Task 11: draft tools + `apply_draft/2` + `discard_draft/1`

**Files:**
- Create: `lib/ganesha/assistant/tools/propose_payment_draft.ex`
- Create: `lib/ganesha/assistant/tools/propose_attendance_draft.ex`
- Create: `lib/ganesha/assistant/tools/propose_makeup_draft.ex`
- Modify: `lib/ganesha/assistant.ex` (add `apply_draft/2`, `discard_draft/1`, `tools/0`, `teacher_system_prompt/0`, `group_system_prompt/0`)
- Test: `test/ganesha/assistant/tools/propose_payment_draft_test.exs`
- Test: `test/ganesha/assistant/tools/propose_attendance_draft_test.exs`
- Test: `test/ganesha/assistant/tools/propose_makeup_draft_test.exs`
- Modify: `test/ganesha/assistant_test.exs` (apply/discard tests)

**Interfaces:**
- Consumes: `Ganesha.Sales.{record_payment/1, confirm_payment/2}`, `Ganesha.Roster.create_attendance/1` (existing).
- Produces: three more `Ganesha.Assistant.Tool` implementations completing the 8-tool roster from the spec; `Ganesha.Assistant.apply_draft/2`, `Ganesha.Assistant.discard_draft/1`, `Ganesha.Assistant.tools/0`, `Ganesha.Assistant.teacher_system_prompt/0`, `Ganesha.Assistant.group_system_prompt/0`.

`apply_draft/2` is the **only** path from a `pending` draft to a real ledger row (spec §8 guardrail #1 and #4) — payment drafts still go through `Sales.confirm_payment/2`, so the existing payment-trust invariant is untouched.

- [ ] **Step 1: Write the failing draft-tool tests**

```elixir
defmodule Ganesha.Assistant.Tools.ProposePaymentDraftTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tools.ProposePaymentDraft

  test "creates a pending payment draft on the thread" do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Assistant.append_message(thread, "user", "2.Lulu （Line pay 1200元）", nil)

    {content, draft_id} =
      ProposePaymentDraft.call(
        %{"amount" => 1200, "method" => "line_pay", "confidence" => 0.8},
        thread
      )

    assert content =~ "draft"
    draft = Assistant.get_draft!(draft_id)
    assert draft.kind == "payment"
    assert draft.state == "pending"
    assert draft.parsed["amount"] == 1200
    assert draft.confidence == 0.8
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.ProposeAttendanceDraftTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tools.ProposeAttendanceDraft
  alias Ganesha.People

  test "creates a pending attendance draft" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, _} = Assistant.append_message(thread, "user", "幫我標記今天 Lulu 缺席", nil)
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {_content, draft_id} =
      ProposeAttendanceDraft.call(%{"session_id" => 1, "student_id" => student.id, "kind" => "enrolled"}, thread)

    draft = Assistant.get_draft!(draft_id)
    assert draft.kind == "attendance"
    assert draft.parsed["session_id"] == 1
  end

  test "reports an unknown student_id instead of creating a draft against no one" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {content, draft_id} =
      ProposeAttendanceDraft.call(%{"session_id" => 1, "student_id" => 999, "kind" => "enrolled"}, thread)

    assert draft_id == nil
    assert content =~ "no student found"
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.ProposeMakeupDraftTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tools.ProposeMakeupDraft

  test "creates a pending makeup_request draft" do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Assistant.append_message(thread, "user", "蘭子補課8/17or 8/31", nil)

    {_content, draft_id} =
      ProposeMakeupDraft.call(%{"note" => "8/17 或 8/31", "confidence" => 0.5}, thread)

    draft = Assistant.get_draft!(draft_id)
    assert draft.kind == "makeup_request"
    assert draft.parsed["note"] == "8/17 或 8/31"
  end
end
```

- [ ] **Step 2: Write the failing `apply_draft/2`/`discard_draft/1` tests**

Add to `test/ganesha/assistant_test.exs`:

```elixir
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  describe "apply_draft/2 and discard_draft/1" do
    test "applying a payment draft records and confirms a payment" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
      {:ok, purchase} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "payment",
          parsed: %{
            "purchase_id" => purchase.id,
            "amount" => 400,
            "method" => "cash",
            "paid_on" => Date.to_iso8601(Ganesha.Clock.today())
          }
        })

      assert {:ok, updated} = Assistant.apply_draft(draft, "line:teacher")
      assert updated.state == "applied"
      assert updated.applied_record_type == "Ganesha.Sales.Payment"

      [payment] = Sales.list_payments_for_purchase(purchase.id)
      assert payment.state == "confirmed"
      assert payment.source == "line_draft"
    end

    test "applying a payment draft with no paid_on defaults to today" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
      {:ok, purchase} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "payment",
          parsed: %{"purchase_id" => purchase.id, "amount" => 400, "method" => "cash"}
        })

      assert {:ok, _updated} = Assistant.apply_draft(draft, "line:teacher")

      [payment] = Sales.list_payments_for_purchase(purchase.id)
      assert payment.paid_on == Ganesha.Clock.today()
    end

    test "applying a payment draft without a purchase_id fails instead of guessing" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "payment", parsed: %{"amount" => 400}})

      assert {:error, :missing_purchase_id} = Assistant.apply_draft(draft, "line:teacher")
      assert Assistant.get_draft!(draft.id).state == "pending"
    end

    test "applying an attendance draft creates an attendance row" do
      {:ok, slot} =
        Studio.create_slot(%{
          weekday: 1,
          start_time: ~T[09:00:00],
          end_time: ~T[10:00:00],
          default_style: "Hatha",
          label: "一"
        })

      {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-09-14], style: "Hatha"})
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "attendance",
          parsed: %{"session_id" => session.id, "student_id" => student.id, "kind" => "drop_in"}
        })

      assert {:ok, updated} = Assistant.apply_draft(draft, "line:teacher")
      assert updated.applied_record_type == "Ganesha.Roster.Attendance"
      assert [attendance] = Roster.list_for_session(session)
      assert attendance.student_id == student.id
    end

    test "applying an attendance draft proposing a makeup is refused, never books one for free" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "attendance",
          parsed: %{"session_id" => 1, "student_id" => student.id, "kind" => "makeup"}
        })

      assert {:error, :makeup_requires_credit} = Assistant.apply_draft(draft, "line:teacher")
      assert Assistant.get_draft!(draft.id).state == "pending"
      assert Roster.list_for_student(student.id) == []
    end

    test "applying a makeup_request draft marks it applied without creating a ledger row" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

      assert {:ok, updated} = Assistant.apply_draft(draft, "line:teacher")
      assert updated.state == "applied"
      assert is_nil(updated.applied_record_type)
    end

    test "applying or discarding an already-resolved draft fails cleanly" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})
      {:ok, discarded} = Assistant.discard_draft(draft)

      assert {:error, :not_pending} = Assistant.discard_draft(discarded)
      assert {:error, :not_pending} = Assistant.apply_draft(discarded, "line:teacher")
    end
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/tools/propose_payment_draft_test.exs test/ganesha/assistant/tools/propose_attendance_draft_test.exs test/ganesha/assistant/tools/propose_makeup_draft_test.exs test/ganesha/assistant_test.exs`
Expected: FAIL — draft tool modules and `apply_draft/2`/`discard_draft/1` undefined.

- [ ] **Step 4: Implement the draft tools**

```elixir
defmodule Ganesha.Assistant.Tools.ProposePaymentDraft do
  @moduledoc """
  Creates a pending payment draft (spec §4, §5). Supplying `purchase_id` is
  optional here — an agent that has already called `student_history` can
  resolve it itself; when omitted, `Ganesha.Assistant.apply_draft/2` refuses
  to guess and routes the teacher to the in-app edit flow instead.
  """
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Assistant, People}

  @impl true
  def name, do: "propose_payment_draft"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Proposes a draft payment for the teacher to confirm. Never applies itself.",
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          purchase_id: %{type: "integer"},
          amount: %{type: "integer"},
          method: %{type: "string", enum: ["line_pay", "line_bank", "cash", "other"]},
          paid_on: %{type: "string", description: "ISO 8601 date"},
          reported_last5: %{type: "string"},
          note: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["amount", "method"]
      }
    }
  end

  @impl true
  def call(input, thread) do
    {confidence, parsed} = Map.pop(input, "confidence", 1.0)
    student_id = Map.get(parsed, "student_id")

    case resolve_student(student_id) do
      {:error, message} ->
        {message, nil}

      :ok ->
        {:ok, draft} =
          Assistant.create_draft(thread, %{
            kind: "payment",
            student_id: student_id,
            parsed: Map.delete(parsed, "student_id"),
            confidence: confidence
          })

        {"draft ##{draft.id} created (payment, pending confirmation)", draft.id}
    end
  end

  defp resolve_student(nil), do: :ok

  defp resolve_student(student_id) do
    if Enum.any?(People.list_students(), &(&1.id == student_id)) do
      :ok
    else
      {:error, "no student found with id #{student_id}"}
    end
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.ProposeAttendanceDraft do
  @moduledoc "Creates a pending attendance draft (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Assistant, People}

  @impl true
  def name, do: "propose_attendance_draft"

  @impl true
  def schema do
    %{
      name: name(),
      description:
        "Proposes a draft attendance change for the teacher to confirm. A real makeup " <>
          "(kind \"makeup\") is never proposed here — use propose_makeup_draft instead, " <>
          "since booking a makeup must consume a credit and only a human confirming an " <>
          "in-app makeup flow can do that.",
      input_schema: %{
        type: "object",
        properties: %{
          session_id: %{type: "integer"},
          student_id: %{type: "integer"},
          kind: %{type: "string", enum: ["enrolled", "drop_in", "trial"]},
          note: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["session_id", "student_id", "kind"]
      }
    }
  end

  @impl true
  def call(input, thread) do
    {confidence, parsed} = Map.pop(input, "confidence", 1.0)
    student_id = Map.get(parsed, "student_id")

    case resolve_student(student_id) do
      {:error, message} ->
        {message, nil}

      :ok ->
        {:ok, draft} =
          Assistant.create_draft(thread, %{
            kind: "attendance",
            student_id: student_id,
            parsed: parsed,
            confidence: confidence
          })

        {"draft ##{draft.id} created (attendance, pending confirmation)", draft.id}
    end
  end

  defp resolve_student(nil), do: :ok

  defp resolve_student(student_id) do
    if Enum.any?(People.list_students(), &(&1.id == student_id)) do
      :ok
    else
      {:error, "no student found with id #{student_id}"}
    end
  end
end
```

```elixir
defmodule Ganesha.Assistant.Tools.ProposeMakeupDraft do
  @moduledoc """
  Records that a student mentioned wanting a makeup, without a concrete
  session yet (spec §4, §5, original design §5.4's `makeup_request` kind).
  Applying this draft never books a makeup itself — only
  `Ganesha.Roster.book_makeup/3`, called from a human action once she
  picks a date, does that.
  """
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Assistant, People}

  @impl true
  def name, do: "propose_makeup_draft"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Records an unresolved makeup request the teacher will schedule by hand.",
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          note: %{type: "string"},
          confidence: %{type: "number"}
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def call(input, thread) do
    {confidence, parsed} = Map.pop(input, "confidence", 1.0)
    student_id = Map.get(parsed, "student_id")

    case resolve_student(student_id) do
      {:error, message} ->
        {message, nil}

      :ok ->
        {:ok, draft} =
          Assistant.create_draft(thread, %{
            kind: "makeup_request",
            student_id: student_id,
            parsed: parsed,
            confidence: confidence
          })

        {"draft ##{draft.id} created (makeup request, pending confirmation)", draft.id}
    end
  end

  defp resolve_student(nil), do: :ok

  defp resolve_student(student_id) do
    if Enum.any?(People.list_students(), &(&1.id == student_id)) do
      :ok
    else
      {:error, "no student found with id #{student_id}"}
    end
  end
end
```

- [ ] **Step 5: Implement `apply_draft/2`, `discard_draft/1`, and the tool/prompt registry**

Add to `lib/ganesha/assistant.ex`:

```elixir
  alias Ganesha.Assistant.Tools.{
    FindStudent,
    ProposeAttendanceDraft,
    ProposeMakeupDraft,
    ProposePaymentDraft,
    StudentBalance,
    StudentHistory,
    TodayRoster,
    UpcomingSessions
  }

  @doc "The full tool roster — identical for the group and teacher threads (spec §2, §4, §5, §8)."
  def tools do
    [
      FindStudent,
      StudentBalance,
      TodayRoster,
      UpcomingSessions,
      StudentHistory,
      ProposePaymentDraft,
      ProposeAttendanceDraft,
      ProposeMakeupDraft
    ]
  end

  @studio_vocabulary """
  只用繁體中文回覆，語氣專業、簡潔，使用瑜珈教室慣用詞彙（堂數、補課、單堂、體驗、
  月課程）。你可以查詢學生、堂數與帳務資料，也可以建立「草稿」（付款、出席、補課
  需求）供她確認 — 你永遠不能把草稿直接變成正式紀錄，只有她本人確認後才算數。
  """

  def teacher_system_prompt do
    "你是師父的課程記帳助理，正在跟她本人對話。" <> @studio_vocabulary
  end

  def group_system_prompt do
    "你正在被動觀察師父的學生群組對話，任何人都看不到你的回覆 — 你唯一能做的事是視
    情況建立草稿供師父之後確認，絕不能、也沒有管道對群組發送任何訊息。" <> @studio_vocabulary
  end

  def apply_draft(%Draft{state: "pending", kind: "payment"} = draft, confirmed_by) do
    with {:ok, purchase_id} <- fetch_purchase_id(draft) do
      Repo.transaction(fn ->
        payment_attrs =
          draft.parsed
          |> Map.put("purchase_id", purchase_id)
          |> Map.put("source", "line_draft")
          |> Map.put_new("paid_on", Date.to_iso8601(Clock.today()))

        with {1, _} <- claim_pending(draft.id),
             {:ok, payment} <- Sales.record_payment(payment_attrs),
             {:ok, payment} <- Sales.confirm_payment(payment, confirmed_by),
             {:ok, updated} <-
               draft |> Draft.apply_changeset("Ganesha.Sales.Payment", payment.id) |> Repo.update() do
          updated
        else
          {0, _} -> Repo.rollback(:not_pending)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  # A "makeup" attendance draft only ever books through
  # `Roster.book_makeup/3`'s credit-consuming transaction, called from a
  # human action in the app — never through here. Without this guard,
  # confirming such a draft would insert a `kind: "makeup"` attendance row
  # with no credit ever spent, silently granting a free class the student
  # could then also redeem again through the normal in-app flow.
  def apply_draft(%Draft{state: "pending", kind: "attendance", parsed: %{"kind" => "makeup"}}, _confirmed_by) do
    {:error, :makeup_requires_credit}
  end

  def apply_draft(%Draft{state: "pending", kind: "attendance"} = draft, _confirmed_by) do
    # Narrowed to exactly what the tool's schema declares — `parsed` is
    # LLM-authored JSON, and `Attendance.changeset/2` would otherwise cast
    # `state`, `purchase_id`, and `credit_id` straight out of it.
    attendance_attrs = Map.take(draft.parsed, ["session_id", "student_id", "kind", "note"])

    Repo.transaction(fn ->
      with {1, _} <- claim_pending(draft.id),
           {:ok, attendance} <- Roster.create_attendance(attendance_attrs),
           {:ok, updated} <-
             draft |> Draft.apply_changeset("Ganesha.Roster.Attendance", attendance.id) |> Repo.update() do
        updated
      else
        {0, _} -> Repo.rollback(:not_pending)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def apply_draft(%Draft{state: "pending", kind: kind} = draft, _confirmed_by)
      when kind in ["makeup_request", "unknown"] do
    mark_applied(draft, nil, nil)
  end

  def apply_draft(%Draft{state: state}, _confirmed_by) when state != "pending", do: {:error, :not_pending}

  def discard_draft(%Draft{state: "pending"} = draft), do: draft |> Draft.state_changeset("discarded") |> Repo.update()
  def discard_draft(%Draft{}), do: {:error, :not_pending}

  defp fetch_purchase_id(%Draft{parsed: %{"purchase_id" => id}}) when not is_nil(id), do: {:ok, id}
  defp fetch_purchase_id(%Draft{}), do: {:error, :missing_purchase_id}

  # Atomically claims exclusive rights to apply this draft: a compare-and-set
  # on `state == "pending"` so two concurrent confirms (or a retried Oban job
  # racing a postback tap) can never both proceed past this point. Runs
  # inside the caller's `Repo.transaction/1`, so a later step failing rolls
  # this flip back too — the draft genuinely stays "pending" unless the
  # ledger write it guards actually lands.
  defp claim_pending(id) do
    Repo.update_all(from(d in Draft, where: d.id == ^id and d.state == "pending"), set: [state: "applied"])
  end

  defp mark_applied(draft, record_type, record_id) do
    draft |> Draft.apply_changeset(record_type, record_id) |> Repo.update()
  end
```

Add the three new aliases this needs near the top of `lib/ganesha/assistant.ex`, alongside the existing `alias Ganesha.Assistant.Thread` (`Ganesha.Clock` for `apply_draft/2`'s payment-date default; `Ganesha.{Roster, Sales}` as before):

```elixir
  alias Ganesha.{Clock, Roster, Sales}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/tools/propose_payment_draft_test.exs test/ganesha/assistant/tools/propose_attendance_draft_test.exs test/ganesha/assistant/tools/propose_makeup_draft_test.exs test/ganesha/assistant_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/ganesha/assistant.ex lib/ganesha/assistant/tools/propose_payment_draft.ex lib/ganesha/assistant/tools/propose_attendance_draft.ex lib/ganesha/assistant/tools/propose_makeup_draft.ex test/ganesha/assistant/tools test/ganesha/assistant_test.exs
git commit -m "feat: add draft tools, apply_draft/2, discard_draft/1"
```

---

## Task 12: `Ganesha.Line.Client` (Req-based LINE API) + `Client.Mock`

**Files:**
- Create: `lib/ganesha/line/client_behaviour.ex`
- Create: `lib/ganesha/line/client.ex`
- Create: `lib/ganesha/line/client/mock.ex`
- Modify: `config/test.exs`
- Test: `test/ganesha/line/client/mock_test.exs`

**Interfaces:**
- Produces: `@callback reply/2`, `@callback push/2`, `@callback get_group_member/2`; `Ganesha.Line.Client` (production, Req-based); `Ganesha.Line.Client.Mock` (test-only, records calls); `Ganesha.Line.Client.text_message/1,2` (quick-reply template builder).

Consumers call through `Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)` (added in Task 15) rather than the module directly, so the group-thread safety guarantee in Task 17 can assert on the mock's recorded calls instead of hitting the network.

- [ ] **Step 1: Add test config**

Add to `config/test.exs`:

```elixir
config :ganesha, :line_client, Ganesha.Line.Client.Mock
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Ganesha.Line.Client.MockTest do
  use ExUnit.Case, async: true
  alias Ganesha.Line.Client.Mock

  test "records reply and push calls for assertions" do
    assert :ok = Mock.reply("rt-1", [%{type: "text", text: "hi"}])
    assert :ok = Mock.push("U1", [%{type: "text", text: "hi"}])

    assert Mock.calls() == [
             {:reply, {"rt-1", [%{type: "text", text: "hi"}]}},
             {:push, {"U1", [%{type: "text", text: "hi"}]}}
           ]
  end

  test "get_group_member/2 returns a canned profile" do
    assert {:ok, %{"displayName" => _}} = Mock.get_group_member("Cabc", "U1")
  end
end
```

```elixir
defmodule Ganesha.Line.ClientTest do
  use ExUnit.Case, async: true
  alias Ganesha.Line.Client

  test "text_message/1 builds a plain text message" do
    assert Client.text_message("嗨") == %{type: "text", text: "嗨"}
  end

  test "text_message/2 attaches a confirm/discard quick reply for a draft id" do
    message = Client.text_message("已建立草稿", 42)
    assert message.type == "text"
    assert [confirm, discard] = message.quickReply.items
    assert confirm.action.data == "action=confirm&draft_id=42"
    assert confirm.action.label == "確認"
    assert discard.action.data == "action=discard&draft_id=42"
    assert discard.action.label == "捨棄"
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/ganesha/line/client/mock_test.exs test/ganesha/line/client_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 4: Implement**

```elixir
defmodule Ganesha.Line.ClientBehaviour do
  @moduledoc "Contract shared by `Ganesha.Line.Client` and `Ganesha.Line.Client.Mock`."

  @callback reply(reply_token :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback push(to :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback get_group_member(group_id :: String.t(), user_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
```

```elixir
defmodule Ganesha.Line.Client do
  @moduledoc """
  Req-based LINE Messaging API client (spec §2, §5). Reply is free and is
  always tried first; push costs quota and is only the fallback for an
  expired reply token (original design §7.1) — negligible at the teacher's
  1:1 volume.
  """
  @behaviour Ganesha.Line.ClientBehaviour

  @base_url "https://api.line.me"

  @impl true
  def reply(reply_token, messages) when is_list(messages) do
    post("/v2/bot/message/reply", %{replyToken: reply_token, messages: messages})
  end

  @impl true
  def push(to, messages) when is_list(messages) do
    post("/v2/bot/message/push", %{to: to, messages: messages})
  end

  @impl true
  def get_group_member(group_id, user_id) do
    case Req.get(req(), url: "/v2/bot/group/#{group_id}/member/#{user_id}") do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(path, body) do
    case Req.post(req(), url: path, json: body) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    token = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_access_token)
    Req.new(base_url: @base_url, headers: [{"authorization", "Bearer #{token}"}])
  end

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

  defp quick_reply_item(label, data), do: %{type: "action", action: %{type: "postback", label: label, data: data}}
end
```

```elixir
defmodule Ganesha.Line.Client.Mock do
  @moduledoc """
  Test-only `Ganesha.Line.ClientBehaviour`. Records calls in the calling
  process's dictionary — the group-thread safety test (Task 17) asserts on
  `calls/0` to prove the code path never sends anything into the group.
  """
  @behaviour Ganesha.Line.ClientBehaviour

  @impl true
  def reply(reply_token, messages) do
    record(:reply, {reply_token, messages})
    :ok
  end

  @impl true
  def push(to, messages) do
    record(:push, {to, messages})
    :ok
  end

  @impl true
  def get_group_member(_group_id, _user_id), do: {:ok, %{"displayName" => "測試學生"}}

  def calls, do: Process.get(:line_client_mock_calls, []) |> Enum.reverse()

  defp record(kind, payload) do
    Process.put(:line_client_mock_calls, [{kind, payload} | Process.get(:line_client_mock_calls, [])])
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/ganesha/line/client/mock_test.exs test/ganesha/line/client_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/line/client_behaviour.ex lib/ganesha/line/client.ex lib/ganesha/line/client/mock.ex config/test.exs test/ganesha/line/client/mock_test.exs test/ganesha/line/client_test.exs
git commit -m "feat: add Line.Client (Req) and a recording mock for tests"
```

---

## Task 13: `Ganesha.Assistant.Provider.Anthropic`

**Files:**
- Create: `lib/ganesha/assistant/provider/anthropic.ex`
- Test: `test/ganesha/assistant/provider/anthropic_test.exs`

**Interfaces:**
- Consumes: `Application.fetch_env!(:ganesha, Ganesha.Assistant.Provider.Anthropic)`.
- Produces: `Ganesha.Assistant.Provider.Anthropic` (implements `Ganesha.Assistant.Provider`), tested against a stubbed `Req` transport (no live network calls).

- [ ] **Step 1: Write the failing test**

`Req` supports a `:plug` transport option for exactly this kind of test — pass a function that receives the `Plug.Conn` and returns a fabricated response, so no real HTTP call is made.

```elixir
defmodule Ganesha.Assistant.Provider.AnthropicTest do
  use ExUnit.Case, async: true
  alias Ganesha.Assistant.Provider.Anthropic

  setup do
    Application.put_env(:ganesha, Anthropic, api_key: "test-key", model: "claude-test")
    on_exit(fn -> Application.delete_env(:ganesha, Anthropic) end)
  end

  test "translates a text-only response into {text, []}" do
    stub = fn conn ->
      body = %{"content" => [%{"type" => "text", "text" => "哈囉"}]}
      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    messages = [%{role: "user", content: "hi"}]
    assert {:ok, %{text: "哈囉", tool_calls: []}} = Anthropic.complete(messages, [], system: "sys", plug: stub)
  end

  test "translates a tool_use response into text + tool_calls" do
    stub = fn conn ->
      body = %{
        "content" => [
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "find_student", "input" => %{"query" => "Lulu"}}
        ]
      }

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    assert {:ok, %{text: nil, tool_calls: [%{id: "toolu_1", name: "find_student", input: %{"query" => "Lulu"}}]}} =
             Anthropic.complete([], [], system: "sys", plug: stub)
  end

  test "surfaces a non-200 response as an error" do
    stub = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end
    assert {:error, {:http_error, 401, "unauthorized"}} = Anthropic.complete([], [], system: "sys", plug: stub)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha/assistant/provider/anthropic_test.exs`
Expected: FAIL — `Ganesha.Assistant.Provider.Anthropic` is undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Ganesha.Assistant.Provider.Anthropic do
  @moduledoc """
  Req-based Anthropic Messages API adapter (`POST /v1/messages`) — the
  concrete `Ganesha.Assistant.Provider` used outside tests (spec §6). The
  `:plug` option in `opts` lets tests substitute a stub transport instead of
  a real network call, per `Req`'s own testing support.
  """
  @behaviour Ganesha.Assistant.Provider

  @base_url "https://api.anthropic.com"
  @api_version "2023-06-01"

  @impl true
  def complete(messages, tools, opts) do
    config = Application.fetch_env!(:ganesha, __MODULE__)
    api_key = Keyword.fetch!(config, :api_key)
    model = Keyword.fetch!(config, :model)
    system = Keyword.get(opts, :system, "")

    body = %{
      model: model,
      max_tokens: 1024,
      system: system,
      messages: Enum.map(messages, &to_wire_message/1),
      tools: Enum.map(tools, &to_wire_tool/1)
    }

    req_opts =
      [base_url: @base_url, headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}]]
      |> then(fn base -> if plug = opts[:plug], do: base ++ [plug: plug], else: base end)

    case Req.post(Req.new(req_opts), url: "/v1/messages", json: body) do
      {:ok, %Req.Response{status: 200, body: response_body}} -> {:ok, from_wire_response(response_body)}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_wire_message(%{role: "user", content: content}) when is_binary(content) do
    %{role: "user", content: content}
  end

  defp to_wire_message(%{role: "assistant", content: content, tool_calls: tool_calls}) do
    blocks =
      (if content, do: [%{type: "text", text: content}], else: []) ++
        Enum.map(tool_calls || [], fn call ->
          %{type: "tool_use", id: call.id, name: call.name, input: call.input}
        end)

    %{role: "assistant", content: blocks}
  end

  defp to_wire_message(%{role: "tool", tool_calls: results}) do
    blocks = Enum.map(results, &%{type: "tool_result", tool_use_id: &1.tool_use_id, content: &1.content})
    %{role: "user", content: blocks}
  end

  defp to_wire_tool(%{name: name, description: description, input_schema: input_schema}) do
    %{name: name, description: description, input_schema: input_schema}
  end

  defp from_wire_response(%{"content" => blocks}) do
    text = Enum.find_value(blocks, fn %{"type" => t} = b -> t == "text" && b["text"] end)

    tool_calls =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(&%{id: &1["id"], name: &1["name"], input: &1["input"]})

    %{text: text, tool_calls: tool_calls}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ganesha/assistant/provider/anthropic_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/provider/anthropic.ex test/ganesha/assistant/provider/anthropic_test.exs
git commit -m "feat: add the Anthropic Provider adapter"
```

---

## Task 14: config for LINE, the Anthropic provider, and the teacher's LINE user id

**Files:**
- Modify: `config/runtime.exs`

**Interfaces:**
- Produces: `config :ganesha, :line, channel_secret:, channel_access_token:, teacher_line_user_id:`; `config :ganesha, Ganesha.Assistant.Provider.Anthropic, api_key:, model:`; `config :ganesha, :assistant, provider:`.

No test changes — `config/test.exs` already carries its own values from Tasks 5, 7, and 12. This task only makes `mix phx.server` (dev) and a release (prod) boot with real configuration, matching the existing `secret_key_base`/`database_path` raise-if-missing pattern in `config/runtime.exs`.

- [ ] **Step 1: Add the prod block**

`config/runtime.exs` currently ends its `if config_env() == :prod do ... end` block with the mailer comment. Insert before that block's closing `end`:

```elixir
  line_channel_secret =
    System.get_env("LINE_CHANNEL_SECRET") ||
      raise "environment variable LINE_CHANNEL_SECRET is missing"

  line_channel_access_token =
    System.get_env("LINE_CHANNEL_ACCESS_TOKEN") ||
      raise "environment variable LINE_CHANNEL_ACCESS_TOKEN is missing"

  teacher_line_user_id =
    System.get_env("TEACHER_LINE_USER_ID") ||
      raise "environment variable TEACHER_LINE_USER_ID is missing"

  config :ganesha, :line,
    channel_secret: line_channel_secret,
    channel_access_token: line_channel_access_token,
    teacher_line_user_id: teacher_line_user_id

  anthropic_api_key =
    System.get_env("ANTHROPIC_API_KEY") ||
      raise "environment variable ANTHROPIC_API_KEY is missing"

  config :ganesha, Ganesha.Assistant.Provider.Anthropic,
    api_key: anthropic_api_key,
    model: System.get_env("ANTHROPIC_MODEL") || "claude-sonnet-4-5-20250929"

  config :ganesha, :assistant, provider: Ganesha.Assistant.Provider.Anthropic
```

- [ ] **Step 2: Add a non-raising dev block**

Add a new block to `config/runtime.exs`, after the existing `if config_env() == :dev do ... end` block that configures `live_reload`:

```elixir
if config_env() == :dev do
  config :ganesha, :line,
    channel_secret: System.get_env("LINE_CHANNEL_SECRET", ""),
    channel_access_token: System.get_env("LINE_CHANNEL_ACCESS_TOKEN", ""),
    teacher_line_user_id: System.get_env("TEACHER_LINE_USER_ID", "")

  config :ganesha, Ganesha.Assistant.Provider.Anthropic,
    api_key: System.get_env("ANTHROPIC_API_KEY", ""),
    model: System.get_env("ANTHROPIC_MODEL") || "claude-sonnet-4-5-20250929"

  config :ganesha, :assistant, provider: Ganesha.Assistant.Provider.Anthropic
end
```

`mix phx.server` boots with empty secrets in dev; the webhook signature check simply rejects everything until real values are exported (this is a local dev convenience, not a security boundary — dev is never internet-facing without deliberately tunneling it).

- [ ] **Step 3: Run the full suite to confirm nothing in :test or :dev config compilation broke**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS — `config/test.exs` is untouched and still wins for `MIX_ENV=test` (Task 5/7/12's explicit test values are not overridden by these `:prod`/`:dev`-gated blocks).

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs
git commit -m "feat: configure LINE and Anthropic secrets for dev and prod"
```

---

## Task 15: `ProcessEventWorker` — teacher 1:1 thread end to end

**Files:**
- Create: `lib/ganesha/assistant/process_event_worker.ex`
- Test: `test/ganesha/assistant/process_event_worker_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Line.{get_event!/1, mark_processed/1}` (Task 1), `Ganesha.Assistant.{tools/0, teacher_system_prompt/0}` (Task 11), `Ganesha.Assistant.Agent.run/3` (Task 8), `Ganesha.Line.Client` behind `Application.get_env(:ganesha, :line_client, ...)` (Task 12).
- Produces: `Ganesha.Assistant.ProcessEventWorker` (`Oban.Worker`), fully exercising Task 1's `enqueue/1` call for the first time.

Only the teacher-thread branch is implemented here; `route/2`'s catch-all clause makes every other event (including group messages, handled in Task 17) a safe no-op for now.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ganesha.Assistant.ProcessEventWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.ProcessEventWorker
  alias Ganesha.Assistant.Provider.Mock
  alias Ganesha.Line.Client.Mock, as: LineMock

  defp enqueue_teacher_message(text) do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-#{System.unique_integer([:positive])}",
        "type" => "message",
        "mode" => "active",
        "source" => %{"type" => "user", "userId" => "Uteacher0000000000000000000000"},
        "replyToken" => "rt-1",
        "message" => %{"id" => "linemsg-#{System.unique_integer([:positive])}", "type" => "text", "text" => text}
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    job
  end

  test "answers via reply and marks the event processed" do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "目前沒有人欠錢。", tool_calls: []}} end)
    job = enqueue_teacher_message("誰欠錢？")

    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:reply, {"rt-1", [%{type: "text", text: "目前沒有人欠錢。"}]}}] = LineMock.calls()

    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    assert [%{content: "誰欠錢？"}, %{content: "目前沒有人欠錢。"}] = Assistant.list_messages(thread)

    line_event = Line.get_event!(job.args["line_event_id"])
    assert line_event.processed_at
  end

  test "falls back to push when the reply token has already expired" do
    Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "好的", tool_calls: []}} end)

    defmodule ExpiredReplyLineMock do
      @behaviour Ganesha.Line.ClientBehaviour
      def reply(_reply_token, _messages), do: {:error, :expired}
      def push(to, messages), do: LineMock.push(to, messages)
      def get_group_member(g, u), do: LineMock.get_group_member(g, u)
    end

    Application.put_env(:ganesha, :line_client, ExpiredReplyLineMock)
    on_exit(fn -> Application.put_env(:ganesha, :line_client, LineMock) end)

    job = enqueue_teacher_message("你好")
    assert :ok = perform_job(ProcessEventWorker, job.args)

    assert [{:push, {"Uteacher0000000000000000000000", [%{type: "text", text: "好的"}]}}] = LineMock.calls()
  end

  test "ignores a message from a non-teacher 1:1 sender" do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-stranger",
        "type" => "message",
        "mode" => "active",
        "source" => %{"type" => "user", "userId" => "Ustranger"},
        "replyToken" => "rt-2",
        "message" => %{"id" => "linemsg-stranger", "type" => "text", "text" => "hi"}
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    assert :ok = perform_job(ProcessEventWorker, job.args)
    assert LineMock.calls() == []
  end
end
```

Since `Process.put`/`Process.get` are per-process and `Ganesha.DataCase` runs each test in its own process, no explicit reset of the `Line.Client.Mock`/`Provider.Mock` process dictionaries between tests is needed.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL — `Ganesha.Assistant.ProcessEventWorker` is undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Ganesha.Assistant.ProcessEventWorker do
  @moduledoc """
  Runs one `line_events` row through the shared agent loop (spec §2). The
  teacher's 1:1 messages get a LINE reply (falling back to push) carrying
  the agent's answer and, when a draft was created, a confirm/discard quick
  reply. Every other event is currently a no-op — group messages are wired
  in by Task 17, postbacks by Task 16.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Agent
  alias Ganesha.Line

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"line_event_id" => line_event_id}}) do
    line_event = Line.get_event!(line_event_id)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    result = route(line_event, teacher_id)
    Line.mark_processed(line_event)
    result
  end

  defp route(%{source_type: "user", source_id: sender_id, raw_type: "message"} = event, teacher_id)
       when sender_id == teacher_id do
    handle_teacher_message(event)
  end

  defp route(_event, _teacher_id), do: :ok

  defp handle_teacher_message(%{
         payload: %{"replyToken" => reply_token, "message" => %{"text" => text}},
         source_id: source_id
       }) do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", source_id)
    {:ok, _} = Assistant.append_message(thread, "user", text, nil)

    case Agent.run(thread, Assistant.tools(), Assistant.teacher_system_prompt()) do
      {:ok, %{text: reply_text, draft_ids: draft_ids}} ->
        send_reply(reply_token, source_id, reply_text, List.first(draft_ids))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_teacher_message(_event), do: :ok

  defp send_reply(reply_token, source_id, text, draft_id) do
    message = line_client().text_message(text, draft_id)

    case line_client().reply(reply_token, [message]) do
      :ok -> :ok
      {:error, _reason} -> line_client().push(source_id, [message])
    end
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Run the full suite — this exercises Task 1's `enqueue/1` for the first time**

Run: `mix test`
Expected: PASS, including `test/ganesha/line_test.exs`'s idempotency test, which now enqueues a real Oban job (`Oban.Testing` is configured `testing: :manual` in `config/test.exs`, so `Oban.insert/1` inserts a row without executing it inline).

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/process_event_worker.ex test/ganesha/assistant/process_event_worker_test.exs
git commit -m "feat: run the teacher's 1:1 thread end to end via ProcessEventWorker"
```

---

## Task 16: postback confirm/discard

**Files:**
- Modify: `lib/ganesha/assistant/process_event_worker.ex`
- Modify: `test/ganesha/assistant/process_event_worker_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.{apply_draft/2, discard_draft/1, get_draft!/1}` (Task 11).
- Produces: postback handling in the existing worker — no new public interface.

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/assistant/process_event_worker_test.exs`:

```elixir
  alias Ganesha.{Catalog, People, Sales}

  defp enqueue_teacher_postback(data) do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-#{System.unique_integer([:positive])}",
        "type" => "postback",
        "mode" => "active",
        "source" => %{"type" => "user", "userId" => "Uteacher0000000000000000000000"},
        "replyToken" => "rt-postback",
        "postback" => %{"data" => data}
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    job
  end

  describe "postback confirm/discard" do
    test "confirm applies a pending payment draft and replies with success" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
      {:ok, purchase} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "payment",
          parsed: %{
            "purchase_id" => purchase.id,
            "amount" => 400,
            "method" => "cash",
            "paid_on" => Date.to_iso8601(Ganesha.Clock.today())
          }
        })

      job = enqueue_teacher_postback("action=confirm&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "applied"
      assert [{:reply, {"rt-postback", [%{type: "text", text: "已確認並記錄。"}]}}] = LineMock.calls()
    end

    test "confirm on a draft missing purchase_id explains why, without applying" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "payment", parsed: %{"amount" => 400}})

      job = enqueue_teacher_postback("action=confirm&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "pending"
      assert [{:reply, {"rt-postback", [%{type: "text", text: text}]}}] = LineMock.calls()
      assert text =~ "App 內編輯"
    end

    test "discard marks a pending draft discarded" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})

      job = enqueue_teacher_postback("action=discard&draft_id=#{draft.id}")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert Assistant.get_draft!(draft.id).state == "discarded"
      assert [{:reply, {"rt-postback", [%{type: "text", text: "已捨棄。"}]}}] = LineMock.calls()
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL — postback events currently fall through `route/2`'s catch-all no-op.

- [ ] **Step 3: Implement**

Add a `route/2` clause and the postback handler to `lib/ganesha/assistant/process_event_worker.ex`, above the existing catch-all clause:

```elixir
  defp route(%{source_type: "user", source_id: sender_id, raw_type: "postback"} = event, teacher_id)
       when sender_id == teacher_id do
    handle_postback(event)
  end
```

```elixir
  defp handle_postback(%{payload: %{"replyToken" => reply_token, "postback" => %{"data" => data}}}) do
    params = URI.decode_query(data)
    draft = Assistant.get_draft!(String.to_integer(params["draft_id"]))
    reply_text = resolve_postback(params["action"], draft)

    line_client().reply(reply_token, [line_client().text_message(reply_text)])
    :ok
  end

  defp resolve_postback("confirm", draft) do
    case Assistant.apply_draft(draft, "line:teacher") do
      {:ok, _} -> "已確認並記錄。"
      {:error, :missing_purchase_id} -> "這筆草稿缺少對應的購買記錄，請於 App 內編輯後確認。"
      {:error, :not_pending} -> "這筆草稿已經處理過了。"
      {:error, _changeset} -> "記錄失敗，請於 App 內手動處理。"
    end
  end

  defp resolve_postback("discard", draft) do
    case Assistant.discard_draft(draft) do
      {:ok, _} -> "已捨棄。"
      {:error, :not_pending} -> "這筆草稿已經處理過了。"
    end
  end

  defp resolve_postback(_unknown, _draft), do: "無法辨識的操作。"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/assistant/process_event_worker.ex test/ganesha/assistant/process_event_worker_test.exs
git commit -m "feat: apply or discard a draft from a LINE postback tap"
```

---

## Task 17: group thread + structural safety guardrail

**Files:**
- Modify: `lib/ganesha/assistant/process_event_worker.ex`
- Modify: `test/ganesha/assistant/process_event_worker_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.group_system_prompt/0` (Task 11).
- Produces: group-message handling in the existing worker.

The group branch never references `line_client()` at all — this is the code-level guarantee spec §4.3/§8 calls for (stronger than a tool-registry check: there is no code path in this branch that can reach the LINE send API, regardless of what the agent's text output says).

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/assistant/process_event_worker_test.exs`:

```elixir
  defp enqueue_group_message(sender_id, text) do
    :ok =
      Line.record_event(%{
        "webhookEventId" => "evt-#{System.unique_integer([:positive])}",
        "type" => "message",
        "mode" => "active",
        "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => sender_id},
        "message" => %{"id" => "linemsg-#{System.unique_integer([:positive])}", "type" => "text", "text" => text}
      })

    [job] = all_enqueued(worker: ProcessEventWorker)
    job
  end

  describe "group thread" do
    test "processes a student message into thread history without ever calling Line.Client" do
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "(internal reasoning, never sent)", tool_calls: []}} end)

      job = enqueue_group_message("Ustudent1", "2.Lulu （Line pay 1200元）")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert [%{role: "user", content: "2.Lulu （Line pay 1200元）"}, %{role: "assistant"}] =
               Assistant.list_messages(thread)
    end

    test "the teacher's own posts in the group are not treated as student input" do
      job = enqueue_group_message("Uteacher0000000000000000000000", "大家好")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert Assistant.list_messages(thread) == []
    end

    test "a group message can still produce a pending draft, never an applied one" do
      Process.put(:calls, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        case Process.get(:calls) do
          0 ->
            Process.put(:calls, 1)

            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{
                   id: "t1",
                   name: "propose_payment_draft",
                   input: %{"amount" => 1200, "method" => "line_pay", "confidence" => 0.8}
                 }
               ]
             }}

          1 ->
            {:ok, %{text: "logged internally", tool_calls: []}}
        end
      end)

      job = enqueue_group_message("Ustudent1", "2.Lulu （Line pay 1200元）")
      assert :ok = perform_job(ProcessEventWorker, job.args)

      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      drafts = Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id))
      assert [%Assistant.Draft{state: "pending", kind: "payment"}] = drafts
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL — group events currently fall through the catch-all no-op, so the thread never gets the message.

- [ ] **Step 3: Implement**

Add a `route/2` clause to `lib/ganesha/assistant/process_event_worker.ex`, above the catch-all:

```elixir
  defp route(%{source_type: "group", source_id: group_id, raw_type: "message"} = event, teacher_id) do
    sender_id = get_in(event.payload, ["source", "userId"])

    if sender_id == teacher_id do
      :ok
    else
      handle_group_message(event, group_id)
    end
  end
```

```elixir
  # No `line_client()` call anywhere in this function or anything it calls —
  # that absence, not a runtime check, is what guarantees the group never
  # receives a message from the bot (spec §4.3, §8 guardrail #2).
  defp handle_group_message(%{payload: %{"message" => %{"text" => text}}}, group_id) do
    {:ok, thread} = Assistant.get_or_create_thread("group", group_id)
    {:ok, _} = Assistant.append_message(thread, "user", text, nil)

    case Agent.run(thread, Assistant.tools(), Assistant.group_system_prompt()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_group_message(_event, _group_id), do: :ok
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `mix test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/process_event_worker.ex test/ganesha/assistant/process_event_worker_test.exs
git commit -m "feat: process group messages with no code path to Line.Client"
```

---

## Task 18: retention sweep for group-thread raw text

**Files:**
- Create: `lib/ganesha/assistant/purge_group_raw_text_worker.ex`
- Modify: `config/config.exs:27-34`
- Test: `test/ganesha/assistant/purge_group_raw_text_worker_test.exs`

**Interfaces:**
- Produces: `Ganesha.Assistant.PurgeGroupRawTextWorker` (`Oban.Worker`, cron-scheduled hourly alongside the existing `CloseMonthWorker`).

Only the group's raw text is in scope — `drafts.parsed` and the teacher's own thread are exempt by design (spec §7), so this worker never touches `drafts` or `teacher`-source threads at all.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Ganesha.Assistant.PurgeGroupRawTextWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Line, Repo}
  alias Ganesha.Assistant.PurgeGroupRawTextWorker

  defp insert_old_line_event(source_type, source_id) do
    old = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60, :second) |> DateTime.truncate(:second)

    {:ok, event} =
      %Line.LineEvent{}
      |> Line.LineEvent.changeset(%{
        webhook_event_id: "evt-#{System.unique_integer([:positive])}",
        source_type: source_type,
        source_id: source_id,
        raw_type: "message",
        payload: %{"message" => %{"text" => "secret"}}
      })
      |> Repo.insert()

    event |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
  end

  defp insert_old_message(thread, content) do
    old = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60, :second) |> DateTime.truncate(:second)
    {:ok, message} = Assistant.append_message(thread, "user", content, nil)
    message |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
  end

  test "purges group line_events payload older than 24h" do
    event = insert_old_line_event("group", "Cabc")
    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})
    assert Line.get_event!(event.id).payload == %{"purged" => true}
  end

  test "does not purge the teacher's own 1:1 line_events" do
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)
    event = insert_old_line_event("user", teacher_id)
    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})
    assert Line.get_event!(event.id).payload == %{"message" => %{"text" => "secret"}}
  end

  test "purges group thread message content older than 24h, leaves the teacher thread alone" do
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, teacher_thread} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

    group_message = insert_old_message(group_thread, "2.Lulu （Line pay 1200元）")
    teacher_message = insert_old_message(teacher_thread, "誰欠錢？")

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert Repo.get!(Assistant.Message, group_message.id).content == nil
    assert Repo.get!(Assistant.Message, teacher_message.id).content == "誰欠錢？"
  end

  test "leaves recent group messages untouched" do
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, recent} = Assistant.append_message(group_thread, "user", "剛剛的訊息", nil)

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert Repo.get!(Assistant.Message, recent.id).content == "剛剛的訊息"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/ganesha/assistant/purge_group_raw_text_worker_test.exs`
Expected: FAIL — `Ganesha.Assistant.PurgeGroupRawTextWorker` is undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Ganesha.Assistant.PurgeGroupRawTextWorker do
  @moduledoc """
  Hourly sweep enforcing the 24h raw-text retention window for anything
  sourced from the group, or from an unrecognised 1:1 sender — the
  teacher's own thread and `drafts.parsed` are exempt (spec §7).
  """
  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Ganesha.Assistant.{Message, Thread}
  alias Ganesha.Line.LineEvent
  alias Ganesha.Repo

  @retention_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_seconds, :second)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    purge_line_events(cutoff, teacher_id)
    purge_group_messages(cutoff)

    :ok
  end

  defp purge_line_events(cutoff, teacher_id) do
    from(e in LineEvent,
      where: e.inserted_at < ^cutoff,
      where: not (e.source_type == "user" and e.source_id == ^teacher_id)
    )
    |> Repo.update_all(set: [payload: %{"purged" => true}])
  end

  defp purge_group_messages(cutoff) do
    group_thread_ids = from(t in Thread, where: t.source_type == "group", select: t.id)

    from(m in Message,
      where: m.thread_id in subquery(group_thread_ids),
      where: m.inserted_at < ^cutoff,
      where: not is_nil(m.content)
    )
    |> Repo.update_all(set: [content: nil])
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/ganesha/assistant/purge_group_raw_text_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Schedule it in cron, alongside the existing `CloseMonthWorker`**

`config/config.exs:27-34` currently reads:

```elixir
config :ganesha, Oban,
  repo: Ganesha.Repo,
  engine: Oban.Engines.Lite,
  queues: [default: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron, crontab: [{"10 16 * * *", Ganesha.Reporting.CloseMonthWorker}]}
  ]
```

Replace with:

```elixir
config :ganesha, Oban,
  repo: Ganesha.Repo,
  engine: Oban.Engines.Lite,
  queues: [default: 5],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"10 16 * * *", Ganesha.Reporting.CloseMonthWorker},
       {"0 * * * *", Ganesha.Assistant.PurgeGroupRawTextWorker}
     ]}
  ]
```

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/ganesha/assistant/purge_group_raw_text_worker.ex config/config.exs test/ganesha/assistant/purge_group_raw_text_worker_test.exs
git commit -m "feat: purge group-thread raw text hourly at the 24h retention window"
```

---

## Task 19: unsend and messageEdited correctness events

**Files:**
- Modify: `lib/ganesha/assistant/process_event_worker.ex`
- Modify: `test/ganesha/assistant/process_event_worker_test.exs`

**Interfaces:**
- Consumes: `Ganesha.Assistant.Message.line_message_id` (Task 3), `Ganesha.Assistant.discard_draft/1` (Task 11), `Ganesha.Assistant.Agent.run/3` (Task 8).
- Produces: `unsend`/`messageEdited` handling in the existing worker; `handle_teacher_message/1` and `handle_group_message/2` (Tasks 15, 17) now stamp `line_message_id` on ingestion, which they didn't need until this task.

Reuses the original design's §5.6 correctness rule: `unsend` deletes raw text and any **pending** draft derived from it, never an applied one; an edit re-runs the agent against the corrected text and replaces the pending draft.

- [ ] **Step 1: Write the failing tests**

Add to `test/ganesha/assistant/process_event_worker_test.exs`:

```elixir
  describe "unsend and messageEdited" do
    test "unsend clears the message content and discards its pending draft" do
      Process.put(:calls, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        case Process.get(:calls) do
          0 ->
            Process.put(:calls, 1)

            {:ok,
             %{
               text: nil,
               tool_calls: [
                 %{id: "t1", name: "propose_payment_draft", input: %{"amount" => 1200, "method" => "line_pay"}}
               ]
             }}

          _ ->
            {:ok, %{text: "logged", tool_calls: []}}
        end
      end)

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-msg",
          "type" => "message",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => "Ustudent1"},
          "message" => %{"id" => "linemsg-1", "type" => "text", "text" => "2.Lulu （Line pay 1200元）"}
        })

      [msg_job] = all_enqueued(worker: ProcessEventWorker)
      assert :ok = perform_job(ProcessEventWorker, msg_job.args)

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      [draft] = Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id))
      assert draft.state == "pending"

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-unsend",
          "type" => "unsend",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cabc", "userId" => "Ustudent1"},
          "unsend" => %{"messageId" => "linemsg-1"}
        })

      [unsend_job] = all_enqueued(worker: ProcessEventWorker) |> Enum.reject(&(&1.id == msg_job.id))
      assert :ok = perform_job(ProcessEventWorker, unsend_job.args)

      user_message = Assistant.list_messages(thread) |> Enum.find(&(&1.role == "user"))
      assert is_nil(user_message.content)
      assert Assistant.get_draft!(draft.id).state == "discarded"
    end

    test "messageEdited replaces the pending draft with a fresh one from the corrected text" do
      Process.put(:calls, 0)

      Mock.stub(fn _messages, _tools, _opts ->
        case Process.get(:calls) do
          0 ->
            Process.put(:calls, 1)

            {:ok,
             %{text: nil, tool_calls: [%{id: "t1", name: "propose_payment_draft", input: %{"amount" => 900, "method" => "line_pay"}}]}}

          1 ->
            Process.put(:calls, 2)
            {:ok, %{text: "logged", tool_calls: []}}

          2 ->
            Process.put(:calls, 3)

            {:ok,
             %{text: nil, tool_calls: [%{id: "t2", name: "propose_payment_draft", input: %{"amount" => 1200, "method" => "line_pay"}}]}}

          _ ->
            {:ok, %{text: "logged again", tool_calls: []}}
        end
      end)

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-msg2",
          "type" => "message",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cdef", "userId" => "Ustudent2"},
          "message" => %{"id" => "linemsg-2", "type" => "text", "text" => "2.Lulu （Line pay 900元）"}
        })

      [msg_job] = all_enqueued(worker: ProcessEventWorker)
      assert :ok = perform_job(ProcessEventWorker, msg_job.args)

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cdef")
      [original_draft] = Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id))

      :ok =
        Line.record_event(%{
          "webhookEventId" => "evt-edit",
          "type" => "messageEdited",
          "mode" => "active",
          "source" => %{"type" => "group", "groupId" => "Cdef", "userId" => "Ustudent2"},
          "message" => %{"id" => "linemsg-2", "text" => "2.Lulu （Line pay 1200元）"}
        })

      [edit_job] = all_enqueued(worker: ProcessEventWorker) |> Enum.reject(&(&1.id == msg_job.id))
      assert :ok = perform_job(ProcessEventWorker, edit_job.args)

      assert Assistant.get_draft!(original_draft.id).state == "discarded"

      new_drafts =
        Ganesha.Repo.all(Assistant.Draft) |> Enum.filter(&(&1.thread_id == thread.id and &1.state == "pending"))

      assert [%{parsed: %{"amount" => 1200}}] = new_drafts

      user_message = Assistant.list_messages(thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: FAIL — `line_message_id` is never stamped yet, and `unsend`/`messageEdited` fall through the catch-all no-op.

- [ ] **Step 3: Stamp `line_message_id` at ingestion**

In `lib/ganesha/assistant/process_event_worker.ex`, replace only `handle_teacher_message/1`'s first clause (Task 15) — its `defp handle_teacher_message(_event), do: :ok` catch-all clause is unaffected and stays exactly as Task 15 left it:

```elixir
  defp handle_teacher_message(%{
         payload: %{"replyToken" => reply_token, "message" => %{"id" => line_message_id, "text" => text}},
         source_id: source_id
       }) do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", source_id)
    {:ok, _} = Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    case Agent.run(thread, Assistant.tools(), Assistant.teacher_system_prompt()) do
      {:ok, %{text: reply_text, draft_ids: draft_ids}} ->
        send_reply(reply_token, source_id, reply_text, List.first(draft_ids))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
```

And likewise replace only `handle_group_message/2`'s first clause (Task 17) — its `defp handle_group_message(_event, _group_id), do: :ok` catch-all clause is unaffected and stays:

```elixir
  defp handle_group_message(%{payload: %{"message" => %{"id" => line_message_id, "text" => text}}}, group_id) do
    {:ok, thread} = Assistant.get_or_create_thread("group", group_id)
    {:ok, _} = Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    case Agent.run(thread, Assistant.tools(), Assistant.group_system_prompt()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
```

- [ ] **Step 4: Add `unsend` and `messageEdited` routing and handlers**

Add two `route/2` clauses above the catch-all:

```elixir
  defp route(%{raw_type: "unsend"} = event, _teacher_id), do: handle_unsend(event)
  defp route(%{raw_type: "messageEdited"} = event, _teacher_id), do: handle_message_edited(event)
```

Add the handlers and their shared helper:

```elixir
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

  defp handle_message_edited(%{payload: %{"message" => %{"id" => line_message_id, "text" => new_text}}}) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: new_text) |> Repo.update!()
        discard_pending_drafts_for(message)

        thread = Repo.get!(Assistant.Thread, message.thread_id)
        system_prompt = if thread.source_type == "teacher", do: Assistant.teacher_system_prompt(), else: Assistant.group_system_prompt()

        case Agent.run(thread, Assistant.tools(), system_prompt) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp discard_pending_drafts_for(%Assistant.Message{id: id}) do
    from(d in Assistant.Draft, where: d.origin_message_id == ^id and d.state == "pending")
    |> Repo.all()
    |> Enum.each(&Assistant.discard_draft/1)
  end
```

Add the two required aliases and `import Ecto.Query` near the top of `lib/ganesha/assistant/process_event_worker.ex`:

```elixir
  import Ecto.Query

  alias Ganesha.Repo
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: PASS

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS

- [ ] **Step 7: Run `mix precommit` per `AGENTS.md`**

Run: `mix precommit`
Expected: PASS (compile with warnings as errors, unused deps check, format, full test suite)

- [ ] **Step 8: Commit**

```bash
git add lib/ganesha/assistant/process_event_worker.ex test/ganesha/assistant/process_event_worker_test.exs
git commit -m "feat: handle LINE unsend and messageEdited correctness events"
```
