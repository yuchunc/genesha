# LINE Group Blocklist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the teacher block LINE groups and group senders from the Teacher chat, make "never posts in a group" a code-level guarantee, and keep raw LINE text in dev.

**Architecture:** One `blocked_accounts` table in the `Ganesha.Line` context. `ProcessEventWorker` drops blocked groups and senders before storing anything. Group messages record their sender (`sender_id`, `sender_name`). Three Teacher-chat tasks (`listening`, `block_account`, `unblock_account`) read and change the blocklist through Drafts. `Line.record_event/1` strips group reply tokens, and `Line.Client` refuses group and room targets. `PurgeGroupRawTextWorker` becomes a no-op when `:purge_raw_text` is false (dev).

**Tech Stack:** Elixir, Phoenix 1.8, Ecto + `ecto_sqlite3`, Oban (Lite), `Req` + `Req.Test`.

**Spec:** `docs/superpowers/specs/2026-10-05-line-group-blocklist-design.md`

## Global Constraints

- The group path never calls LINE's send APIs (`reply`, `push`, `loading`). Its only LINE calls are the read-only `get_group_member/2` and `get_group_summary/1`.
- `blocked_accounts` changes only through a confirmed Teacher-chat Draft (ADR 0001). `listening`, `block_account` and `unblock_account` are never in `Tasks.for_chat(:group)` or `Tasks.for_chat(:student)`.
- A blocked sender is ignored in every group, keyed by LINE `userId`.
- `:ganesha, :line, :purge_raw_text` defaults to `true`. Only `config/runtime.exs`'s dev block sets it to `false`.
- Summary strings are exactly as written in the spec (§3), in zh-TW and en.
- No new dependencies. Generate migrations with `mix ecto.gen.migration <name>`.
- Run `mix precommit` once all tasks are done, and fix anything it reports.

---

### Task 1: Never-reply guards

**Files:**
- Modify: `lib/ganesha/line.ex` (`record_event/1`)
- Modify: `lib/ganesha/line/client.ex` (`push/2`, `loading/2`)
- Test: `test/ganesha/line_test.exs`, `test/ganesha/line/client_test.exs`

**Interfaces:**
- Produces: group and room `line_events.payload` never contain `"replyToken"`. `Line.Client.push/2` and `loading/2` return `{:error, :group_target_forbidden}` for ids starting with `"C"` or `"R"`.

- [ ] **Step 1: Write the failing tests**

Append to `test/ganesha/line_test.exs` (inside the module; `event/1` is the existing helper):

```elixir
  test "record_event/1 stores group and room events without their reply token" do
    for {type, key, id} <- [{"group", "groupId", "Cg"}, {"room", "roomId", "Rr"}] do
      e =
        event(%{
          "replyToken" => "rt",
          "source" => %{"type" => type, key => id, "userId" => "Ustudent"}
        })

      :ok = Line.record_event(e)
      stored = Repo.get_by!(Line.LineEvent, webhook_event_id: e["webhookEventId"])
      refute Map.has_key?(stored.payload, "replyToken")
    end
  end

  test "record_event/1 keeps a 1:1 event's reply token" do
    e = event(%{"replyToken" => "rt"})
    :ok = Line.record_event(e)

    assert Repo.get_by!(Line.LineEvent, webhook_event_id: e["webhookEventId"]).payload[
             "replyToken"
           ] == "rt"
  end
```

Append to `test/ganesha/line/client_test.exs`:

```elixir
  @tag :capture_log
  test "push/2 and loading/2 refuse group and room targets without calling LINE" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      send(parent, {:called, conn.request_path})
      Req.Test.json(conn, %{})
    end)

    for to <- ["Cgroup", "Rroom"] do
      assert {:error, :group_target_forbidden} = Client.push(to, [Client.text_message("嗨")])
      assert {:error, :group_target_forbidden} = Client.loading(to, 20)
    end

    refute_received {:called, _}
  end
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/line_test.exs test/ganesha/line/client_test.exs`
Expected: 2 failures. The group/room payload still has `"replyToken"`, and `push/2` returns `:ok` instead of the error.

- [ ] **Step 3: Implement**

In `lib/ganesha/line.ex`, change the `payload: event` line in `record_event/1` to `payload: without_group_reply_token(event)`, and add these private functions next to `source_id/1`:

```elixir
  # Spec 2026-10-05 §4: a group or room event is stored without its reply
  # token, so no code path can ever answer into a group.
  defp without_group_reply_token(%{"source" => %{"type" => type}} = event)
       when type in ["group", "room"],
       do: Map.delete(event, "replyToken")

  defp without_group_reply_token(event), do: event
```

In `lib/ganesha/line/client.ex`, add `require Logger` under the `@behaviour` line, then replace `push/2` and `loading/2`:

```elixir
  @impl true
  def push(to, messages) when is_list(messages) do
    with :ok <- refuse_group_target(to) do
      post("/v2/bot/message/push", %{to: to, messages: messages})
    end
  end

  @doc "Shows LINE's loading animation in a 1:1 chat while the assistant thinks (spec §6.1)."
  @impl true
  def loading(chat_id, seconds) when is_integer(seconds) and seconds > 0 do
    with :ok <- refuse_group_target(chat_id) do
      post("/v2/bot/chat/loading/start", %{chatId: chat_id, loadingSeconds: seconds})
    end
  end
```

and add these private functions above `defp post/2`:

```elixir
  # Spec 2026-10-05 §4: the bot never posts into a group (C…) or a room (R…),
  # whichever caller asks.
  defp refuse_group_target("C" <> _ = to), do: forbid(to)
  defp refuse_group_target("R" <> _ = to), do: forbid(to)
  defp refuse_group_target(_to), do: :ok

  defp forbid(to) do
    Logger.error("LINE send to #{to} refused: the bot never posts in groups or rooms")
    {:error, :group_target_forbidden}
  end
```

Update the comment above `handle_group_message` in `lib/ganesha/assistant/process_event_worker.ex` (lines 98-99) to:

```elixir
  # Nothing on this path sends to LINE, and `Line.Client` refuses group
  # targets anyway (spec 2026-10-05 §4): the Group chat never hears from the bot.
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `mix test test/ganesha/line_test.exs test/ganesha/line/client_test.exs test/ganesha/assistant/process_event_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/line.ex lib/ganesha/line/client.ex lib/ganesha/assistant/process_event_worker.ex test/ganesha/line_test.exs test/ganesha/line/client_test.exs
git commit -m "Never reply in LINE groups: drop group reply tokens, refuse group targets"
```

---

### Task 2: `blocked_accounts` table and `Ganesha.Line` blocklist API

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_blocked_accounts.exs` (via `mix ecto.gen.migration create_blocked_accounts`)
- Create: `lib/ganesha/line/blocked_account.ex`
- Modify: `lib/ganesha/line.ex`
- Test: `test/ganesha/line/blocked_accounts_test.exs`

**Interfaces:**
- Produces:
  - `Ganesha.Line.BlockedAccount` with fields `kind` (`"group" | "sender"`), `line_id`, `label`, `inserted_at`
  - `Ganesha.Line.blocked?(kind :: String.t(), line_id :: String.t() | nil) :: boolean()`
  - `Ganesha.Line.get_blocked_account(kind, line_id) :: BlockedAccount.t() | nil`
  - `Ganesha.Line.list_blocked_accounts() :: [BlockedAccount.t()]`, newest first
  - `Ganesha.Line.block_account(%{kind:, line_id:, label:}) :: {:ok, BlockedAccount.t()} | {:error, :already_blocked | Ecto.Changeset.t()}`
  - `Ganesha.Line.unblock_account(kind, line_id) :: :ok | {:error, :not_blocked}`

- [ ] **Step 1: Write the failing test**

Create `test/ganesha/line/blocked_accounts_test.exs`:

```elixir
defmodule Ganesha.Line.BlockedAccountsTest do
  use Ganesha.DataCase

  alias Ganesha.Line

  test "a block applies to its kind only" do
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})

    assert Line.blocked?("sender", "Umei")
    refute Line.blocked?("group", "Umei")
    refute Line.blocked?("sender", "Uother")
    refute Line.blocked?("sender", nil)
  end

  test "blocking twice reports already blocked" do
    {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "瑜伽週三班"})

    assert {:error, :already_blocked} =
             Line.block_account(%{kind: "group", line_id: "Cabc", label: "瑜伽週三班"})
  end

  test "unblock deletes the row; a second unblock reports not blocked" do
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})

    assert :ok = Line.unblock_account("sender", "Umei")
    refute Line.blocked?("sender", "Umei")
    assert Line.get_blocked_account("sender", "Umei") == nil
    assert {:error, :not_blocked} = Line.unblock_account("sender", "Umei")
  end

  test "rejects an unknown kind" do
    assert {:error, %Ecto.Changeset{}} =
             Line.block_account(%{kind: "room", line_id: "Rr", label: "x"})
  end

  test "lists newest first" do
    {:ok, first} = Line.block_account(%{kind: "sender", line_id: "U1", label: "一"})
    {:ok, second} = Line.block_account(%{kind: "sender", line_id: "U2", label: "二"})

    assert Enum.map(Line.list_blocked_accounts(), & &1.id) == [second.id, first.id]
  end
end
```

- [ ] **Step 2: Run the test to make sure it fails**

Run: `mix test test/ganesha/line/blocked_accounts_test.exs`
Expected: FAIL with `UndefinedFunctionError ... Ganesha.Line.block_account/1`

- [ ] **Step 3: Generate and write the migration**

Run: `mix ecto.gen.migration create_blocked_accounts`, then set the generated file's body:

```elixir
defmodule Ganesha.Repo.Migrations.CreateBlockedAccounts do
  use Ecto.Migration

  def change do
    create table(:blocked_accounts) do
      add :kind, :string, null: false
      add :line_id, :string, null: false
      add :label, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:blocked_accounts, [:kind, :line_id])
  end
end
```

- [ ] **Step 4: Write the schema**

Create `lib/ganesha/line/blocked_account.ex`:

```elixir
defmodule Ganesha.Line.BlockedAccount do
  @moduledoc """
  A LINE group, or a group sender, the assistant ignores (spec
  2026-10-05-line-group-blocklist-design.md §1). A blocked sender is ignored
  in every group. Unblocking deletes the row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(group sender)

  schema "blocked_accounts" do
    field :kind, :string
    field :line_id, :string
    field :label, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(blocked_account, attrs) do
    blocked_account
    |> cast(attrs, [:kind, :line_id, :label])
    |> validate_required([:kind, :line_id, :label])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:kind, :line_id])
  end
end
```

- [ ] **Step 5: Add the context functions**

In `lib/ganesha/line.ex`:

- Add `import Ecto.Query, only: [from: 2]` under `require Logger`.
- Change `alias Ganesha.Line.LineEvent` to `alias Ganesha.Line.{BlockedAccount, LineEvent}`.
- In `record_event/1`, change `if unique_violation?(changeset), do: :ok, else: {:error, changeset}` to `if unique_violation?(changeset, :webhook_event_id), do: :ok, else: {:error, changeset}`.
- Replace `unique_violation?/1` with:

```elixir
  defp unique_violation?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end
```

- Add above `get_event!/1`:

```elixir
  @doc "Whether a group (`\"group\"`) or a sender in every group (`\"sender\"`) is blocked."
  @spec blocked?(String.t(), String.t() | nil) :: boolean()
  def blocked?(_kind, nil), do: false

  def blocked?(kind, line_id) do
    Repo.exists?(from b in BlockedAccount, where: b.kind == ^kind and b.line_id == ^line_id)
  end

  def get_blocked_account(kind, line_id),
    do: Repo.get_by(BlockedAccount, kind: kind, line_id: line_id)

  @doc "Every blocked group and sender, newest first."
  def list_blocked_accounts do
    Repo.all(from b in BlockedAccount, order_by: [desc: b.inserted_at, desc: b.id])
  end

  @doc "Applied by a confirmed `block_account` Draft only (ADR 0001)."
  def block_account(attrs) do
    case %BlockedAccount{} |> BlockedAccount.changeset(attrs) |> Repo.insert() do
      {:ok, blocked} ->
        {:ok, blocked}

      {:error, changeset} ->
        if unique_violation?(changeset, :kind),
          do: {:error, :already_blocked},
          else: {:error, changeset}
    end
  end

  @doc "Applied by a confirmed `unblock_account` Draft only (ADR 0001)."
  def unblock_account(kind, line_id) do
    case Repo.delete_all(
           from b in BlockedAccount, where: b.kind == ^kind and b.line_id == ^line_id
         ) do
      {0, _} -> {:error, :not_blocked}
      {_, _} -> :ok
    end
  end
```

- [ ] **Step 6: Migrate and run the tests**

Run: `mix ecto.migrate && mix test test/ganesha/line/blocked_accounts_test.exs test/ganesha/line_test.exs`
Expected: PASS. If `blocking twice reports already blocked` fails with a changeset, run `IO.inspect(changeset.errors)` and match the error key ecto_sqlite3 reports for the composite index (it should be `:kind`, the first field).

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/*_create_blocked_accounts.exs lib/ganesha/line/blocked_account.ex lib/ganesha/line.ex test/ganesha/line/blocked_accounts_test.exs
git commit -m "Add blocked_accounts and the Ganesha.Line blocklist API"
```

---

### Task 3: Group summary lookup and `Line.group_name/1`

**Files:**
- Modify: `lib/ganesha/line/client_behaviour.ex`, `lib/ganesha/line/client.ex`, `lib/ganesha/line/client/mock.ex`, `lib/ganesha/line.ex`
- Test: `test/ganesha/line/client_test.exs`, `test/ganesha/line_test.exs`

**Interfaces:**
- Produces:
  - `Line.Client.get_group_summary(group_id) :: {:ok, map()} | {:error, term()}` (`GET /v2/bot/group/{id}/summary`, body has `"groupName"`)
  - `Line.group_name(group_id) :: String.t()`: the group's name, or the id when LINE can't say
  - `Line.Client.Mock`:
    - `get_group_member/2` returns `Process.get(:line_client_mock_group_member, {:ok, %{"displayName" => "測試學生"}})`
    - `get_group_summary/1` returns `Process.get(:line_client_mock_group_summary, {:ok, %{"groupName" => "測試群組"}})`
    - both are recorded in `Mock.lookups/0`, never in `Mock.calls/0`

- [ ] **Step 1: Write the failing tests**

Append to `test/ganesha/line/client_test.exs`:

```elixir
  test "get_group_summary/1 fetches the group's name" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      send(parent, {:request, conn.method, conn.request_path})
      Req.Test.json(conn, %{"groupId" => "Cabc", "groupName" => "瑜伽週三班"})
    end)

    assert {:ok, %{"groupName" => "瑜伽週三班"}} = Client.get_group_summary("Cabc")
    assert_receive {:request, "GET", "/v2/bot/group/Cabc/summary"}
  end
```

Append to `test/ganesha/line_test.exs`:

```elixir
  test "group_name/1 is the group's LINE name" do
    Process.put(:line_client_mock_group_summary, {:ok, %{"groupName" => "瑜伽週三班"}})
    assert Line.group_name("Cabc") == "瑜伽週三班"
  end

  @tag :capture_log
  test "group_name/1 falls back to the id when LINE can't say" do
    Process.put(:line_client_mock_group_summary, {:error, {404, %{}}})
    assert Line.group_name("Cabc") == "Cabc"
  end
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/line/client_test.exs test/ganesha/line_test.exs`
Expected: FAIL with `UndefinedFunctionError` for `get_group_summary/1` and `group_name/1`

- [ ] **Step 3: Implement**

`lib/ganesha/line/client_behaviour.ex`: add the callback:

```elixir
  @callback get_group_summary(group_id :: String.t()) :: {:ok, map()} | {:error, term()}
```

`lib/ganesha/line/client.ex`: replace `get_group_member/2` with these two functions plus a shared private `get/1`:

```elixir
  @impl true
  def get_group_member(group_id, user_id),
    do: get("/v2/bot/group/#{group_id}/member/#{user_id}")

  @doc "The group's name and picture; read-only (spec 2026-10-05 §3)."
  @impl true
  def get_group_summary(group_id), do: get("/v2/bot/group/#{group_id}/summary")

  defp get(path) do
    case Req.get(req(), url: path) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
```

`lib/ganesha/line/client/mock.ex`: replace `get_group_member/2` and add the summary and lookups:

```elixir
  @impl true
  def get_group_member(group_id, user_id) do
    record_lookup({:group_member, group_id, user_id})
    Process.get(:line_client_mock_group_member, {:ok, %{"displayName" => "測試學生"}})
  end

  @impl true
  def get_group_summary(group_id) do
    record_lookup({:group_summary, group_id})
    Process.get(:line_client_mock_group_summary, {:ok, %{"groupName" => "測試群組"}})
  end

  @doc "Read-only lookups, kept out of `calls/0` so the never-sends assertions stay exact."
  def lookups, do: Process.get(:line_client_mock_lookups, []) |> Enum.reverse()

  defp record_lookup(lookup) do
    Process.put(:line_client_mock_lookups, [lookup | Process.get(:line_client_mock_lookups, [])])
  end
```

`lib/ganesha/line.ex`: add above `get_event!/1`:

```elixir
  @doc """
  The group's LINE name, or its id when LINE can't say (spec 2026-10-05 §3).
  Read-only.
  """
  @spec group_name(String.t()) :: String.t()
  def group_name(group_id) when is_binary(group_id) do
    case line_client().get_group_summary(group_id) do
      {:ok, %{"groupName" => name}} when is_binary(name) and name != "" ->
        name

      other ->
        Logger.warning("LINE group summary failed for #{group_id}: #{inspect(other)}")
        group_id
    end
  end
```

and at the bottom of the module:

```elixir
  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `mix test test/ganesha/line`
Expected: PASS (including the existing `mock_test.exs`)

- [ ] **Step 5: Commit**

```bash
git add lib/ganesha/line/client_behaviour.ex lib/ganesha/line/client.ex lib/ganesha/line/client/mock.ex lib/ganesha/line.ex test/ganesha/line/client_test.exs test/ganesha/line_test.exs
git commit -m "Add LINE group summary lookup and Line.group_name/1"
```

---

### Task 4: Record group senders; drop blocked groups and senders

**Files:**
- Create: `priv/repo/migrations/<timestamp>_add_sender_to_assistant_messages.exs` (via `mix ecto.gen.migration add_sender_to_assistant_messages`)
- Modify: `lib/ganesha/assistant/message.ex`, `lib/ganesha/assistant.ex` (`append_message/5`), `lib/ganesha/assistant/process_event_worker.ex`
- Test: `test/ganesha/assistant/process_event_worker_test.exs`

**Interfaces:**
- Consumes: `Line.blocked?/2` (Task 2), `Mock.lookups/0` and `:line_client_mock_group_member` (Task 3)
- Produces:
  - `assistant_messages.sender_id` and `sender_name` (both nullable strings)
  - `Assistant.append_message(thread, role, content, tool_calls, line_message_id: _, sender_id: _, sender_name: _)`

- [ ] **Step 1: Write the failing tests**

In `test/ganesha/assistant/process_event_worker_test.exs`, add to `describe "Group chat"`:

```elixir
    test "stores the sender's id and LINE display name with the message" do
      Process.put(:line_client_mock_group_member, {:ok, %{"displayName" => "小美"}})
      Mock.stub(fn _messages, _tools, _opts -> {:ok, %{text: "ok", tool_calls: []}} end)

      {:ok, _} = deliver(group_text("Ustudent1", "大家好"))

      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{role: "user", sender_id: "Ustudent1", sender_name: "小美"}, _] =
               Assistant.list_messages(thread)
    end

    @tag :capture_log
    test "a failed member lookup still runs the agent, with no sender name" do
      Process.put(:line_client_mock_group_member, {:error, {404, %{}}})

      Mock.stub(fn _messages, _tools, _opts ->
        Process.put(:agent_ran, true)
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      {:ok, _} = deliver(group_text("Ustudent1", "大家好"))

      assert Process.get(:agent_ran)
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      assert [%{sender_id: "Ustudent1", sender_name: nil}, _] =
               Assistant.list_messages(thread)
    end

    test "a blocked group is dropped before anything is stored or looked up" do
      {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "測試群組"})

      Mock.stub(fn _messages, _tools, _opts ->
        Process.put(:agent_ran, true)
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      assert {:ok, _} = deliver(group_text("Ustudent1", "2.Lulu （Line pay 1200元）"))

      refute Process.get(:agent_ran)
      assert LineMock.lookups() == []
      assert LineMock.calls() == []
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      assert Assistant.list_messages(thread) == []
    end

    test "a blocked sender is dropped in every group" do
      {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Uspam", label: "廣告"})

      Mock.stub(fn _messages, _tools, _opts ->
        Process.put(:agent_ran, true)
        {:ok, %{text: "ok", tool_calls: []}}
      end)

      other_group = %{
        "type" => "message",
        "source" => %{"type" => "group", "groupId" => "Cother", "userId" => "Uspam"},
        "message" => %{"id" => new_line_message_id(), "type" => "text", "text" => "買課送課"}
      }

      assert {:ok, _} = deliver(group_text("Uspam", "買課送課"))
      assert {:ok, _} = deliver(other_group)

      refute Process.get(:agent_ran)
      assert LineMock.lookups() == []

      for group_id <- ["Cabc", "Cother"] do
        {:ok, thread} = Assistant.get_or_create_thread("group", group_id)
        assert Assistant.list_messages(thread) == []
      end
    end
```

Add to `describe "unsend and messageEdited"` (its setup runs rounds 0 and 1 and leaves one pending Draft):

```elixir
    test "messageEdited in a blocked group updates the text without re-running the agent", c do
      {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "測試群組"})

      assert {:ok, _} =
               deliver(%{
                 "type" => "messageEdited",
                 "source" => group_source("Ustudent1"),
                 "message" => %{"id" => "linemsg-1", "text" => "2.Lulu （Line pay 1200元）"}
               })

      assert Process.get(:round) == 2
      assert Assistant.get_draft!(c.draft.id).state == "discarded"
      assert Repo.all(from d in Assistant.Draft, where: d.state == "pending") == []

      user_message = Assistant.list_messages(c.thread) |> Enum.find(&(&1.role == "user"))
      assert user_message.content == "2.Lulu （Line pay 1200元）"
    end
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: the five new tests FAIL. Messages have no `sender_id` key, and blocked groups/senders still reach the agent.

- [ ] **Step 3: Add the columns**

Run: `mix ecto.gen.migration add_sender_to_assistant_messages`, then set the body:

```elixir
defmodule Ganesha.Repo.Migrations.AddSenderToAssistantMessages do
  use Ecto.Migration

  def change do
    alter table(:assistant_messages) do
      add :sender_id, :string
      add :sender_name, :string
    end
  end
end
```

In `lib/ganesha/assistant/message.ex`, add these fields after `field :line_message_id, :string`:

```elixir
    # Group chat only (spec 2026-10-05 §1); purged with `content` in prod.
    field :sender_id, :string
    field :sender_name, :string
```

and change the `cast` list to `[:thread_id, :role, :content, :tool_calls, :line_message_id, :sender_id, :sender_name]`.

In `lib/ganesha/assistant.ex` `append_message/5`, add to the attrs map:

```elixir
      sender_id: opts[:sender_id],
      sender_name: opts[:sender_name]
```

- [ ] **Step 4: Route around blocks and record the sender**

In `lib/ganesha/assistant/process_event_worker.ex`, replace the group `route/1` clause (lines 55-60) with:

```elixir
  # Spec 2026-10-05 §2: a blocked group, a teacher's own post, or a blocked
  # sender is dropped before anything is stored, looked up or sent to the model.
  defp route(%{source_type: "group", source_id: group_id, raw_type: "message"} = event) do
    sender_id = get_in(event.payload, ["source", "userId"])

    cond do
      Line.blocked?("group", group_id) -> :ok
      Line.teacher?(sender_id) -> :ok
      Line.blocked?("sender", sender_id) -> :ok
      true -> handle_group_message(event, group_id, sender_id)
    end
  end
```

Replace both `handle_group_message` clauses with:

```elixir
  defp handle_group_message(
         %{payload: %{"message" => %{"id" => line_message_id, "text" => text}}},
         group_id,
         sender_id
       ) do
    {:ok, thread} = Assistant.get_or_create_thread("group", group_id)

    {:ok, _} =
      Assistant.append_message(thread, "user", text, nil,
        line_message_id: line_message_id,
        sender_id: sender_id,
        sender_name: sender_name(group_id, sender_id)
      )

    thread |> run_group_agent() |> log_failure(thread, "group message")
    maybe_schedule_group_notifier(thread)
  end

  defp handle_group_message(_event, _group_id, _sender_id), do: :ok

  # Read-only: the display name the teacher blocks by (spec 2026-10-05 §1).
  defp sender_name(_group_id, nil), do: nil

  defp sender_name(group_id, sender_id) do
    case line_client().get_group_member(group_id, sender_id) do
      {:ok, %{"displayName" => name}} ->
        name

      other ->
        Logger.warning("LINE group member lookup failed for #{sender_id}: #{inspect(other)}")
        nil
    end
  end
```

In `handle_message_edited/1`, replace everything from `result =` to the closing `if thread.source_type == "group", ...` line with:

```elixir
        rerun_after_edit(thread)
```

and add below `handle_message_edited/1`:

```elixir
  defp rerun_after_edit(%{source_type: "group", source_id: group_id} = thread) do
    if Line.blocked?("group", group_id) do
      :ok
    else
      thread |> run_group_agent() |> log_failure(thread, "messageEdited")
      maybe_schedule_group_notifier(thread)
    end
  end

  defp rerun_after_edit(thread) do
    thread |> Conversation.run_turn() |> log_failure(thread, "messageEdited")
  end
```

Add at the bottom of the module:

```elixir
  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
```

- [ ] **Step 5: Migrate and run the tests**

Run: `mix ecto.migrate && mix test test/ganesha/assistant/process_event_worker_test.exs`
Expected: PASS (all old and new tests)

- [ ] **Step 6: Commit**

```bash
git add priv/repo/migrations/*_add_sender_to_assistant_messages.exs lib/ganesha/assistant/message.ex lib/ganesha/assistant.ex lib/ganesha/assistant/process_event_worker.ex test/ganesha/assistant/process_event_worker_test.exs
git commit -m "Record group senders; drop blocked groups and senders before the agent"
```

---

### Task 5: `listening` lookup

**Files:**
- Modify: `lib/ganesha/assistant.ex`
- Create: `lib/ganesha/assistant/tasks/listening.ex`
- Test: `test/ganesha/assistant/tasks/listening_test.exs`

**Interfaces:**
- Consumes: `Line.list_blocked_accounts/0` (Task 2), `Line.group_name/1` (Task 3), `sender_id`/`sender_name` (Task 4)
- Produces:
  - `Assistant.group_senders(thread, limit) :: [%{sender_id: String.t(), sender_name: String.t() | nil, last_seen_at: DateTime.t()}]`, most recent first
  - `Assistant.find_group_sender(sender_id) :: %{sender_id: String.t(), sender_name: String.t() | nil} | nil`
  - `Ganesha.Assistant.Tasks.Listening`: `name/0` is `"listening"`, `kind/0` is `:lookup`

- [ ] **Step 1: Write the failing test**

Create `test/ganesha/assistant/tasks/listening_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.ListeningTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.Tasks.Listening

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    %{ctx: %{thread: teacher, locale: "zh-TW", today: ~D[2026-10-05]}}
  end

  defp post(thread, sender_id, sender_name) do
    {:ok, _} =
      Assistant.append_message(thread, "user", "hi", nil,
        sender_id: sender_id,
        sender_name: sender_name
      )
  end

  test "says so when the bot has no group yet", c do
    assert {:ok, %{data: data}} = Listening.answer(%{}, c.ctx)
    assert data =~ "none yet"
    assert data =~ "Blocked: nobody."
  end

  test "lists each group by name, its senders newest first, and the blocklist", c do
    Process.put(:line_client_mock_group_summary, {:ok, %{"groupName" => "瑜伽週三班"}})
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    post(group, "Umei", "小美")
    post(group, "Uzhe", "阿哲")
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Uzhe", label: "阿哲"})

    {:ok, %{data: data}} = Listening.answer(%{}, c.ctx)

    assert data =~ "Group 瑜伽週三班 (id Cabc), listening"
    assert data =~ "小美 (id Umei)"
    assert data =~ ~r/阿哲 \(id Uzhe\), last seen [^\n]*, blocked/
    assert data =~ "sender 阿哲 (id Uzhe)"

    {zhe_at, _} = :binary.match(data, "(id Uzhe)")
    {mei_at, _} = :binary.match(data, "(id Umei)")
    assert zhe_at < mei_at
  end

  test "marks a blocked group", c do
    {:ok, _} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "測試群組"})

    {:ok, %{data: data}} = Listening.answer(%{}, c.ctx)
    assert data =~ "(id Cabc), blocked"
  end

  test "find_group_sender/1 finds a sender from any group, nil otherwise" do
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    post(group, "Umei", "小美")

    assert %{sender_id: "Umei", sender_name: "小美"} = Assistant.find_group_sender("Umei")
    assert Assistant.find_group_sender("Unobody") == nil
  end
end
```

- [ ] **Step 2: Run the test to make sure it fails**

Run: `mix test test/ganesha/assistant/tasks/listening_test.exs`
Expected: FAIL with `module Ganesha.Assistant.Tasks.Listening is not available`

- [ ] **Step 3: Add the sender queries**

In `lib/ganesha/assistant.ex`, add after `list_messages/1`:

```elixir
  @doc """
  The senders of a group thread's messages that still carry one, most recently
  seen first (spec 2026-10-05 §3). `sender_name` is a stored non-nil name.
  """
  def group_senders(%Thread{} = thread, limit) when is_integer(limit) do
    Repo.all(
      from m in Message,
        where: m.thread_id == ^thread.id and not is_nil(m.sender_id),
        group_by: m.sender_id,
        order_by: [desc: max(m.inserted_at), desc: max(m.id)],
        limit: ^limit,
        select: %{
          sender_id: m.sender_id,
          sender_name: max(m.sender_name),
          last_seen_at: type(max(m.inserted_at), :utc_datetime)
        }
    )
  end

  @doc "A sender seen in any group thread, or nil (spec 2026-10-05 §3)."
  def find_group_sender(sender_id) when is_binary(sender_id) do
    Repo.one(
      from m in Message,
        join: t in Thread,
        on: t.id == m.thread_id,
        where: t.source_type == "group" and m.sender_id == ^sender_id,
        group_by: m.sender_id,
        select: %{sender_id: m.sender_id, sender_name: max(m.sender_name)}
    )
  end
```

- [ ] **Step 4: Write the task**

Create `lib/ganesha/assistant/tasks/listening.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.Listening do
  @moduledoc """
  Lookup task `listening` (spec 2026-10-05-line-group-blocklist-design.md §3):
  the groups the bot reads, who has posted in each recently, and the
  blocklist. Teacher chat only; the ids it returns are what `block_account`
  and `unblock_account` take.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Clock, Line}

  @senders_per_group 30

  @impl true
  def name, do: "listening"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      The LINE groups you read, who has posted in each recently, and who is blocked. \
      Call it before block_account or unblock_account to get the exact group or sender \
      id, and when the teacher asks which groups or people you listen to.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, _ctx) do
    blocked = Line.list_blocked_accounts()
    blocked_ids = MapSet.new(blocked, &{&1.kind, &1.line_id})

    {:ok, %{data: groups_section(blocked_ids) <> "\n\n" <> blocked_section(blocked)}}
  end

  defp groups_section(blocked_ids) do
    case Assistant.list_threads("group") do
      [] -> "Groups: none yet. No group has sent the bot a message."
      threads -> Enum.map_join(threads, "\n\n", &group_section(&1, blocked_ids))
    end
  end

  defp group_section(thread, blocked_ids) do
    status = if {"group", thread.source_id} in blocked_ids, do: "blocked", else: "listening"
    header = "Group #{Line.group_name(thread.source_id)} (id #{thread.source_id}), #{status}"

    senders =
      case Assistant.group_senders(thread, @senders_per_group) do
        [] -> ["- none"]
        senders -> Enum.map(senders, &sender_line(&1, blocked_ids))
      end

    Enum.join([header, "Recent senders:" | senders], "\n")
  end

  defp sender_line(sender, blocked_ids) do
    blocked = if {"sender", sender.sender_id} in blocked_ids, do: ", blocked", else: ""
    name = sender.sender_name || "(name unknown)"
    "- #{name} (id #{sender.sender_id}), last seen #{taipei_minute(sender.last_seen_at)}#{blocked}"
  end

  defp blocked_section([]), do: "Blocked: nobody."

  defp blocked_section(blocked) do
    lines =
      Enum.map(blocked, fn b ->
        "- #{b.kind} #{b.label} (id #{b.line_id}), since #{Clock.to_taipei_date(b.inserted_at)}"
      end)

    Enum.join(["Blocked:" | lines], "\n")
  end

  defp taipei_minute(utc) do
    utc |> Clock.to_taipei_naive() |> NaiveDateTime.to_string() |> String.slice(0, 16)
  end
end
```

- [ ] **Step 5: Run the test to make sure it passes**

Run: `mix test test/ganesha/assistant/tasks/listening_test.exs`
Expected: PASS. If `last_seen_at` comes back as a string, the `type/2` cast is missing; keep it.

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant.ex lib/ganesha/assistant/tasks/listening.ex test/ganesha/assistant/tasks/listening_test.exs
git commit -m "Add listening lookup: groups, recent senders, blocklist"
```

---

### Task 6: `block_account` / `unblock_account`, registry, teacher prompt

**Files:**
- Modify: `lib/ganesha/assistant.ex` (add `get_group_thread/1`)
- Create: `lib/ganesha/assistant/tasks/block_account.ex`, `lib/ganesha/assistant/tasks/unblock_account.ex`
- Modify: `lib/ganesha/assistant/tasks.ex`, `lib/ganesha/assistant/prompts.ex`
- Test: `test/ganesha/assistant/tasks/block_account_test.exs`, `test/ganesha/assistant/tasks/unblock_account_test.exs`, `test/ganesha/assistant/tasks_test.exs`

**Interfaces:**
- Consumes: `Line.block_account/1`, `Line.unblock_account/2`, `Line.get_blocked_account/2`, `Line.blocked?/2` (Task 2); `Line.group_name/1` (Task 3); `Assistant.find_group_sender/1` (Task 5); `Listening` (Task 5)
- Produces:
  - `Assistant.get_group_thread(group_id) :: Thread.t() | nil`
  - Draft kinds `"block_account"` and `"unblock_account"`, with `parsed` = `%{"kind", "line_id", "label"}`
  - `block_account` apply returns `{"Ganesha.Line.BlockedAccount", id}`; `unblock_account` apply returns `{nil, nil}`

- [ ] **Step 1: Write the failing tests**

Create `test/ganesha/assistant/tasks/block_account_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.BlockAccountTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.Tasks.BlockAccount

  @teacher "Uteacher0000000000000000000000"

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")

    for {id, name} <- [{"Umei", "小美"}, {@teacher, "老師"}] do
      {:ok, _} = Assistant.append_message(group, "user", "hi", nil, sender_id: id, sender_name: name)
    end

    Process.put(:line_client_mock_group_summary, {:ok, %{"groupName" => "瑜伽週三班"}})
    %{ctx: %{thread: teacher, locale: "zh-TW", today: ~D[2026-10-05]}}
  end

  test "propose captures the sender's name; apply blocks them", c do
    assert {:ok, %{student_id: nil, parsed: parsed}} =
             BlockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    assert parsed == %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    refute Line.blocked?("sender", "Umei")

    assert {:ok, {"Ganesha.Line.BlockedAccount", id}} = BlockAccount.apply(parsed, "line:teacher")
    assert %{id: ^id} = Line.get_blocked_account("sender", "Umei")
  end

  test "propose names a group by its LINE name", c do
    assert {:ok, %{parsed: %{"kind" => "group", "label" => "瑜伽週三班"}}} =
             BlockAccount.propose(%{"kind" => "group", "line_id" => "Cabc"}, c.ctx)
  end

  test "propose refuses a teacher, unknown ids, a bad kind, and an account already blocked", c do
    assert {:error, teacher_error} =
             BlockAccount.propose(%{"kind" => "sender", "line_id" => @teacher}, c.ctx)

    assert teacher_error =~ "teacher"

    assert {:error, _} = BlockAccount.propose(%{"kind" => "sender", "line_id" => "Unobody"}, c.ctx)
    assert {:error, _} = BlockAccount.propose(%{"kind" => "group", "line_id" => "Cnowhere"}, c.ctx)
    assert {:error, _} = BlockAccount.propose(%{"kind" => "room", "line_id" => "Rr"}, c.ctx)

    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})
    assert {:error, _} = BlockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)
  end

  test "a second apply of the same Draft fails as already blocked", c do
    {:ok, %{parsed: parsed}} =
      BlockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    {:ok, _} = BlockAccount.apply(parsed, "line:teacher")
    assert {:error, :already_blocked} = BlockAccount.apply(parsed, "line:teacher")
  end

  test "summary says who or what stops being read" do
    sender = %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    group = %{"kind" => "group", "line_id" => "Cabc", "label" => "瑜伽週三班"}

    assert BlockAccount.summary(sender, "zh-TW") == "封鎖 小美：之後所有群組中這個人的訊息都不再讀取"
    assert BlockAccount.summary(sender, "en") == "Block 小美: their messages in every group will be ignored"
    assert BlockAccount.summary(group, "zh-TW") == "封鎖群組「瑜伽週三班」：之後不再讀取這個群組"
    assert BlockAccount.summary(group, "en") == ~s(Block group "瑜伽週三班": stop reading this group)
  end
end
```

Create `test/ganesha/assistant/tasks/unblock_account_test.exs`:

```elixir
defmodule Ganesha.Assistant.Tasks.UnblockAccountTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.Tasks.UnblockAccount

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})
    %{ctx: %{thread: teacher, locale: "zh-TW", today: ~D[2026-10-05]}}
  end

  test "propose copies the label; apply unblocks", c do
    assert {:ok, %{student_id: nil, parsed: parsed}} =
             UnblockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    assert parsed == %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    assert {:ok, {nil, nil}} = UnblockAccount.apply(parsed, "line:teacher")
    refute Line.blocked?("sender", "Umei")
  end

  test "propose refuses an account that is not blocked", c do
    assert {:error, _} = UnblockAccount.propose(%{"kind" => "sender", "line_id" => "Uzhe"}, c.ctx)
    assert {:error, _} = UnblockAccount.propose(%{"kind" => "group", "line_id" => "Umei"}, c.ctx)
  end

  test "apply after the row is gone fails as not blocked", c do
    {:ok, %{parsed: parsed}} =
      UnblockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    :ok = Line.unblock_account("sender", "Umei")
    assert {:error, :not_blocked} = UnblockAccount.apply(parsed, "line:teacher")
  end

  test "summary says who or what is read again" do
    sender = %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    group = %{"kind" => "group", "line_id" => "Cabc", "label" => "瑜伽週三班"}

    assert UnblockAccount.summary(sender, "zh-TW") == "解除封鎖 小美：之後會再讀取這個人在群組中的訊息"
    assert UnblockAccount.summary(sender, "en") == "Unblock 小美: their group messages will be read again"
    assert UnblockAccount.summary(group, "zh-TW") == "解除封鎖群組「瑜伽週三班」：之後會再讀取這個群組"
    assert UnblockAccount.summary(group, "en") == ~s(Unblock group "瑜伽週三班": read this group again)
  end
end
```

Add to `test/ganesha/assistant/tasks_test.exs` (add `BlockAccount, Listening, UnblockAccount` to its `alias Ganesha.Assistant.Tasks.{...}` list):

```elixir
  test "listening, block_account and unblock_account are Teacher chat only" do
    for task <- [Listening, BlockAccount, UnblockAccount] do
      assert task in Tasks.for_chat(:teacher)
      refute task in Tasks.for_chat(:group)
      refute task in Tasks.for_chat(:student)
    end
  end
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/assistant/tasks/block_account_test.exs test/ganesha/assistant/tasks/unblock_account_test.exs test/ganesha/assistant/tasks_test.exs`
Expected: FAIL. The modules don't exist yet.

- [ ] **Step 3: Add `get_group_thread/1`**

In `lib/ganesha/assistant.ex`, after `get_thread!/1`:

```elixir
  @doc "The group thread for a LINE group id, or nil."
  def get_group_thread(group_id) when is_binary(group_id),
    do: Repo.get_by(Thread, source_type: "group", source_id: group_id)
```

- [ ] **Step 4: Write `block_account`**

Create `lib/ganesha/assistant/tasks/block_account.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.BlockAccount do
  @moduledoc """
  `block_account` (spec 2026-10-05-line-group-blocklist-design.md §3): stop
  reading a LINE group, or one sender in every group. Teacher chat only;
  applies through `Ganesha.Line.block_account/1` on Confirm (ADR 0001).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Line}

  @kinds ~w(group sender)

  @impl true
  def name, do: "block_account"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Stop reading a LINE group, or one person's messages in every group (封鎖). This \
      only proposes a Draft; the block starts when the teacher taps Confirm. Take \
      line_id from listening, never from a name you guessed.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          kind: %{type: "string", enum: @kinds},
          line_id: %{type: "string", description: "Group id (C…) or sender id (U…) from listening"}
        },
        required: ["kind", "line_id"]
      }
    }
  end

  @impl true
  def propose(%{"kind" => kind, "line_id" => line_id}, _ctx)
      when kind in @kinds and is_binary(line_id) do
    with {:ok, label} <- resolve(kind, line_id),
         :ok <- not_blocked(kind, line_id) do
      {:ok,
       %{student_id: nil, parsed: %{"kind" => kind, "line_id" => line_id, "label" => label}}}
    end
  end

  def propose(_input, _ctx),
    do: {:error, ~s(kind must be "group" or "sender", and line_id an id from listening)}

  @impl true
  def apply(%{"kind" => kind, "line_id" => line_id, "label" => label}, _confirmed_by) do
    with {:ok, blocked} <- Line.block_account(%{kind: kind, line_id: line_id, label: label}) do
      {:ok, {"Ganesha.Line.BlockedAccount", blocked.id}}
    end
  end

  @impl true
  def summary(%{"kind" => "sender", "label" => label}, "en"),
    do: "Block #{label}: their messages in every group will be ignored"

  def summary(%{"kind" => "sender", "label" => label}, _locale),
    do: "封鎖 #{label}：之後所有群組中這個人的訊息都不再讀取"

  def summary(%{"kind" => "group", "label" => label}, "en"),
    do: ~s(Block group "#{label}": stop reading this group)

  def summary(%{"kind" => "group", "label" => label}, _locale),
    do: "封鎖群組「#{label}」：之後不再讀取這個群組"

  defp resolve("group", group_id) do
    if Assistant.get_group_thread(group_id),
      do: {:ok, Line.group_name(group_id)},
      else: {:error, "No group with id #{group_id}. Call listening for the groups the bot reads."}
  end

  defp resolve("sender", user_id) do
    cond do
      Line.teacher?(user_id) ->
        {:error, "#{user_id} is a teacher; teachers' group posts are already ignored."}

      sender = Assistant.find_group_sender(user_id) ->
        {:ok, sender.sender_name || user_id}

      true ->
        {:error, "No group sender with id #{user_id}. Call listening for recent senders."}
    end
  end

  defp not_blocked(kind, line_id) do
    if Line.blocked?(kind, line_id),
      do: {:error, "#{line_id} is already blocked."},
      else: :ok
  end
end
```

- [ ] **Step 5: Write `unblock_account`**

Create `lib/ganesha/assistant/tasks/unblock_account.ex`:

```elixir
defmodule Ganesha.Assistant.Tasks.UnblockAccount do
  @moduledoc """
  `unblock_account` (spec 2026-10-05-line-group-blocklist-design.md §3): read
  a blocked group or sender again. Teacher chat only; applies through
  `Ganesha.Line.unblock_account/2` on Confirm (ADR 0001).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Line

  @kinds ~w(group sender)

  @impl true
  def name, do: "unblock_account"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Read a blocked LINE group, or a blocked person, again (解除封鎖). This only proposes \
      a Draft; it takes effect when the teacher taps Confirm. Take kind and line_id from \
      the Blocked list in listening.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          kind: %{type: "string", enum: @kinds},
          line_id: %{type: "string"}
        },
        required: ["kind", "line_id"]
      }
    }
  end

  @impl true
  def propose(%{"kind" => kind, "line_id" => line_id}, _ctx)
      when kind in @kinds and is_binary(line_id) do
    case Line.get_blocked_account(kind, line_id) do
      nil ->
        {:error, "#{line_id} is not blocked as a #{kind}. Call listening for the Blocked list."}

      blocked ->
        {:ok,
         %{
           student_id: nil,
           parsed: %{"kind" => kind, "line_id" => line_id, "label" => blocked.label}
         }}
    end
  end

  def propose(_input, _ctx),
    do: {:error, ~s(kind must be "group" or "sender", and line_id an id from listening)}

  @impl true
  def apply(%{"kind" => kind, "line_id" => line_id}, _confirmed_by) do
    with :ok <- Line.unblock_account(kind, line_id), do: {:ok, {nil, nil}}
  end

  @impl true
  def summary(%{"kind" => "sender", "label" => label}, "en"),
    do: "Unblock #{label}: their group messages will be read again"

  def summary(%{"kind" => "sender", "label" => label}, _locale),
    do: "解除封鎖 #{label}：之後會再讀取這個人在群組中的訊息"

  def summary(%{"kind" => "group", "label" => label}, "en"),
    do: ~s(Unblock group "#{label}": read this group again)

  def summary(%{"kind" => "group", "label" => label}, _locale),
    do: "解除封鎖群組「#{label}」：之後會再讀取這個群組"
end
```

- [ ] **Step 6: Register and prompt**

In `lib/ganesha/assistant/tasks.ex`:

- Add `BlockAccount,` after `AskTeacher,`, `Listening,` after `Enroll,`, and `UnblockAccount` (with a comma after `StudentSummary`) to the alias list.
- Change the end of `@teacher` to `@schedule ++ [AskTeacher, SetLanguage, PendingDrafts, Listening, BlockAccount, UnblockAccount]`.

In `lib/ganesha/assistant/prompts.ex` `teacher_rules/0`, add after rule 9:

```
    10. Blocking: to stop or resume reading a group or a person, call listening first, \
    then block_account or unblock_account with the exact kind and id it returned. If a \
    name matches more than one sender, call ask_teacher with the options.
```

- [ ] **Step 7: Run the tests to make sure they pass**

Run: `mix test test/ganesha/assistant`
Expected: PASS (including `conversation_test.exs`, which compares the tool list against `Tasks.for_chat(:teacher)`, and `prompts_test.exs`)

- [ ] **Step 8: Commit**

```bash
git add lib/ganesha/assistant.ex lib/ganesha/assistant/tasks/block_account.ex lib/ganesha/assistant/tasks/unblock_account.ex lib/ganesha/assistant/tasks.ex lib/ganesha/assistant/prompts.ex test/ganesha/assistant/tasks/block_account_test.exs test/ganesha/assistant/tasks/unblock_account_test.exs test/ganesha/assistant/tasks_test.exs
git commit -m "Add block_account and unblock_account Teacher chat tasks"
```

---

### Task 7: Keep raw text in dev; purge senders with text in prod

**Files:**
- Modify: `lib/ganesha/assistant/purge_group_raw_text_worker.ex`, `config/runtime.exs`
- Modify: `docs/superpowers/specs/2026-09-11-line-ai-chat-design.md` (§7), `docs/adr/0003-group-chat-text-is-never-summarized.md`
- Test: `test/ganesha/assistant/purge_group_raw_text_worker_test.exs`

**Interfaces:**
- Consumes: `sender_id`/`sender_name` (Task 4)
- Produces: config key `:ganesha, :line, :purge_raw_text` (default `true`)

- [ ] **Step 1: Write the failing tests**

Append to `test/ganesha/assistant/purge_group_raw_text_worker_test.exs`:

```elixir
  test "clears a group message's sender with its text after 24h" do
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    old = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60, :second) |> DateTime.truncate(:second)

    {:ok, message} =
      Assistant.append_message(group_thread, "user", "hi", nil,
        sender_id: "Umei",
        sender_name: "小美"
      )

    message |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert %{content: nil, sender_id: nil, sender_name: nil} =
             Repo.get!(Assistant.Message, message.id)
  end

  test "keeps everything when purge_raw_text is off (dev)" do
    line_config = Application.fetch_env!(:ganesha, :line)
    on_exit(fn -> Application.put_env(:ganesha, :line, line_config) end)
    Application.put_env(:ganesha, :line, Keyword.put(line_config, :purge_raw_text, false))

    event = insert_old_line_event("group", "Cabc")
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    message = insert_old_message(group_thread, "2.Lulu （Line pay 1200元）")

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert Line.get_event!(event.id).payload == %{"message" => %{"text" => "secret"}}
    assert Repo.get!(Assistant.Message, message.id).content == "2.Lulu （Line pay 1200元）"
  end
```

- [ ] **Step 2: Run the tests to make sure they fail**

Run: `mix test test/ganesha/assistant/purge_group_raw_text_worker_test.exs`
Expected: 2 failures. `sender_id` survives the purge, and the flag is ignored.

- [ ] **Step 3: Implement**

Replace the body of `lib/ganesha/assistant/purge_group_raw_text_worker.ex` from the `@moduledoc` through `purge_group_messages/1` as follows:

```elixir
  @moduledoc """
  Hourly sweep enforcing the 24h raw-text retention window for anything
  sourced from the group, or from an unrecognised 1:1 sender — the
  teacher's own thread and `drafts.parsed` are exempt (spec §7). A group
  message's sender goes with its text. Off when `:line, :purge_raw_text` is
  false, which only dev sets (spec 2026-10-05 §5).
  """
```

```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if purge_raw_text?() do
      cutoff = DateTime.utc_now() |> DateTime.add(-@retention_seconds, :second)

      purge_line_events(cutoff, Ganesha.Line.teacher_ids())
      purge_group_messages(cutoff)
    end

    :ok
  end

  defp purge_raw_text? do
    Application.fetch_env!(:ganesha, :line) |> Keyword.get(:purge_raw_text, true)
  end
```

```elixir
  defp purge_group_messages(cutoff) do
    group_thread_ids = from(t in Thread, where: t.source_type == "group", select: t.id)

    from(m in Message,
      where: m.thread_id in subquery(group_thread_ids),
      where: m.inserted_at < ^cutoff,
      where: not is_nil(m.content) or not is_nil(m.sender_id) or not is_nil(m.sender_name)
    )
    |> Repo.update_all(set: [content: nil, sender_id: nil, sender_name: nil])
  end
```

In `config/runtime.exs`, in the dev `config :ganesha, :line,` block, add after the `simple_reply:` line (adding a trailing comma to it):

```elixir
    # Dev keeps every raw LINE payload and group message for development;
    # prod and test purge at 24h (spec 2026-10-05 §5).
    purge_raw_text: false
```

- [ ] **Step 4: Note the dev exception in the docs**

In `docs/superpowers/specs/2026-09-11-line-ai-chat-design.md` §7, append this bullet after the "Teacher's own thread" bullet:

```markdown
- **Dev exception (2026-10-05).** The 24h purge applies to prod. Dev sets
  `:line, :purge_raw_text` to `false` and keeps every raw payload and group
  message, sender included, for development. Revisit before the prod cutover.
  See `2026-10-05-line-group-blocklist-design.md` §5.
```

In `docs/adr/0003-group-chat-text-is-never-summarized.md`, append:

```markdown

The 24-hour limit is enforced in prod. Dev keeps group text for development (`2026-10-05-line-group-blocklist-design.md` §5); no summary is written from it there either.
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `mix test test/ganesha/assistant/purge_group_raw_text_worker_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/ganesha/assistant/purge_group_raw_text_worker.ex config/runtime.exs docs/superpowers/specs/2026-09-11-line-ai-chat-design.md docs/adr/0003-group-chat-text-is-never-summarized.md test/ganesha/assistant/purge_group_raw_text_worker_test.exs
git commit -m "Keep raw LINE text in dev; purge group senders with their text"
```

---

### Task 8: Setup guide, smoke step, full verification

**Files:**
- Modify: `docs/superpowers/line-setup-guide.html` (step 7)
- Modify: `priv/scripts/line_smoke.exs`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Update setup guide step 7**

In `docs/superpowers/line-setup-guide.html`, replace the body of `<section class="step" id="step-7">` (the `<h2>` through the closing `<p class="muted">`) with:

```html
      <h2>Turn off LINE's own auto-responses; allow groups</h2>
      <p>In <strong>LINE Official Account Manager</strong> → Settings:</p>
      <ul class="checks">
        <li>Response settings → Chat — <strong>Off</strong></li>
        <li>Response settings → Auto-response — <strong>Off</strong></li>
        <li>Response settings → Webhook — <strong>On</strong></li>
        <li>Greeting messages — <strong>Disabled</strong></li>
        <li>Account settings → Allow account to join groups and multi-person chats — <strong>On</strong></li>
      </ul>
      <p class="muted">LINE sends auto-responses itself, so the app's never-post-in-groups guards
        (no group reply tokens stored; <code class="inline">Line.Client</code> refuses group ids)
        can't stop them. Leaving them on would post canned replies into the student group.</p>
```

- [ ] **Step 2: Add smoke Step 11**

In `priv/scripts/line_smoke.exs`:

- Add `blocked_sender_id = "Usmokeblocked0000000000000000"` under `group_id = ...`.
- In `cleanup`, add before the `Repo.delete_all(from(e in LineEvent, ...))` line:

```elixir
  Repo.delete_all(
    from(b in Line.BlockedAccount, where: b.line_id in ^[group_id, blocked_sender_id])
  )
```

- Insert before `# ---------------------------------------------------------------- teardown`:

```elixir
# ---------------------------------------------------------------- Step 11
Smoke.step(11, "teacher blocks a group sender; their next message is ignored")

seen_event = %{
  "webhookEventId" => "smoke-group-3",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-11",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => blocked_sender_id},
  "message" => %{"id" => "smoke-msg-7", "type" => "text", "text" => "大家早安"}
}

:ok = Line.record_event(seen_event)
seen_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-3")

Smoke.check(
  "group event stored without its reply token",
  not Map.has_key?(seen_line_event.payload, "replyToken")
)

ProviderMock.stub(fn _messages, _tools, _opts ->
  {:ok, %{text: "nothing to do", tool_calls: []}}
end)

:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => seen_line_event.id}})

Smoke.check(
  "group message stored with its sender",
  Repo.exists?(
    from m in Message,
      where: m.line_message_id == "smoke-msg-7" and m.sender_id == ^blocked_sender_id
  )
)

block_event = %{
  "webhookEventId" => "smoke-teacher-5",
  "mode" => "active",
  "type" => "message",
  "replyToken" => "smoke-reply-12",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "message" => %{"id" => "smoke-msg-8", "type" => "text", "text" => "封鎖 測試學生"}
}

:ok = Line.record_event(block_event)
block_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-teacher-5")

ProviderMock.stub(fn messages, _tools, _opts ->
  case List.last(messages) do
    %{role: "tool"} ->
      {:ok, %{text: "封鎖草稿等你確認。", tool_calls: []}}

    _ ->
      {:ok,
       %{
         text: nil,
         tool_calls: [
           %{
             id: "smoke-call-6",
             name: "block_account",
             input: %{"kind" => "sender", "line_id" => blocked_sender_id}
           }
         ]
       }}
  end
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => block_line_event.id}})

block_draft =
  Repo.one(
    from d in Draft,
      join: t in Thread,
      on: d.thread_id == t.id,
      where: t.source_id == ^teacher_id and d.kind == "block_account" and d.state == "pending"
  )

Smoke.check("Teacher chat proposes a block_account draft", block_draft != nil)

block_confirm_event = %{
  "webhookEventId" => "smoke-postback-5",
  "mode" => "active",
  "type" => "postback",
  "replyToken" => "smoke-reply-13",
  "source" => %{"type" => "user", "userId" => teacher_id},
  "postback" => %{"data" => "action=confirm&draft_id=#{block_draft && block_draft.id}"}
}

:ok = Line.record_event(block_confirm_event)
block_confirm_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-postback-5")
Process.delete(:line_client_mock_calls)

:ok =
  ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => block_confirm_line_event.id}})

Smoke.check("Confirm blocks the sender", Line.blocked?("sender", blocked_sender_id))

blocked_event = %{
  "webhookEventId" => "smoke-group-4",
  "mode" => "active",
  "type" => "message",
  "source" => %{"type" => "group", "groupId" => group_id, "userId" => blocked_sender_id},
  "message" => %{"id" => "smoke-msg-9", "type" => "text", "text" => "2.SMOKE 小美 Line pay 3200"}
}

:ok = Line.record_event(blocked_event)
blocked_line_event = Repo.get_by!(LineEvent, webhook_event_id: "smoke-group-4")

ProviderMock.stub(fn _messages, _tools, _opts ->
  Process.put(:smoke_blocked_agent_ran, true)
  {:ok, %{text: "should not run", tool_calls: []}}
end)

Process.delete(:line_client_mock_calls)
:ok = ProcessEventWorker.perform(%Oban.Job{args: %{"line_event_id" => blocked_line_event.id}})

Smoke.check(
  "blocked sender's message never reaches the agent",
  Process.get(:smoke_blocked_agent_ran) != true
)

Smoke.check(
  "blocked sender's message is not stored in the group thread",
  not Repo.exists?(from m in Message, where: m.line_message_id == "smoke-msg-9")
)

Smoke.check("NOTHING sent to LINE for the blocked message", LineMock.calls() == [])
```

- [ ] **Step 3: Run the full suite, precommit and the smoke**

Run: `mix precommit`
Expected: compiles without warnings, formatted, all tests pass.

Run: `mix ecto.migrate && mix run priv/scripts/line_smoke.exs`
Expected: `ALL CHECKS PASSED`, including Step 11's checks.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/line-setup-guide.html priv/scripts/line_smoke.exs
git commit -m "Setup guide: group auto-response off; smoke step for blocking a sender"
```
