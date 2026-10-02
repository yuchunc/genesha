# LINE Teacher Assistant — Slice 2 (Questions) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Six Teacher-chat lookup tasks (spec §3.1 #1–6), five Flex card types, `validate_reply/1`, and `mix line.validate_cards`.

**Architecture:** `answer/2` returns `data` and optional `card`; Agent honors `show_card`; `Ganesha.Line.Cards` renders fixed layouts from task-built maps.

**Tech Stack:** Elixir 1.20, Phoenix 1.8.13, Ecto/SQLite, Req 0.7.

**Spec:** `docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md` §9 slice 2.

## Global Constraints

Carry slice 1 constraints forward. Additionally: lookups Teacher-only; `Format.money/1`; membership (not exact-list) `tasks_test` asserts; smoke **Step 7** before teardown; never edit `line_real_turn.exs`; end with `mix precommit`, `source .env.dev && mix run priv/scripts/line_real_questions.exs`, `source .env.dev && mix line.validate_cards`.

## How to use this plan

Each section below is **complete file content** verified green in throwaway worktree `/tmp/plan-slice-2` (`mix test` 517 passed, `mix precommit`).

Implement in order: Format → client validate → labels → lookup helper → cards → six tasks → registry → mix task → prompts rule 8 → conversation_test + smoke Step 7 → real script → precommit.

---

### Task 1 — format.ex

```elixir
defmodule Ganesha.Assistant.Format do
  @moduledoc "Value formatting shared by the assistant tasks' `describe/2` and the LINE cards."

  alias GaneshaWeb.Fmt

  @doc """
  An amount as a Draft card shows it, e.g. `NT$1,600`; anything that is not
  a whole-dollar integer is shown as given.
  """
  def money(n) when is_integer(n), do: "NT$" <> Fmt.amount(n)
  def money(other), do: to_string(other)

  @doc "A Session's day as she reads it: `10/7 週三`, or `Wed 10/7` in English; `\"\"` for nil."
  @spec session_day(Date.t() | nil, String.t() | nil) :: String.t()
  def session_day(nil, _locale), do: ""

  def session_day(%Date{} = date, "en"),
    do: "#{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)}"

  def session_day(%Date{} = date, _locale), do: "#{Fmt.short_date(date)} #{Fmt.weekday(date)}"

  @doc "A month's title: `2026年10月`, or `October 2026` in English."
  @spec month_title(Date.t(), String.t() | nil) :: String.t()
  def month_title(%Date{} = month, "en"), do: Calendar.strftime(month, "%B %Y")
  def month_title(%Date{} = month, _locale), do: Fmt.month_title(month)
end
```

---

### Task 1 — format_test additions

```elixir
defmodule Ganesha.Assistant.FormatTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Format

  describe "money/1" do
    test "groups thousands only from four digits up" do
      assert Format.money(0) == "NT$0"
      assert Format.money(999) == "NT$999"
      assert Format.money(1000) == "NT$1,000"
      assert Format.money(1_234_567) == "NT$1,234,567"
    end

    test "keeps the sign of a negative amount" do
      assert Format.money(-1600) == "NT$−1,600"
    end
  end

  describe "session_day/2" do
    test "reads as she writes it, or weekday first in English" do
      assert Format.session_day(~D[2026-10-07], "zh-TW") == "10/7 週三"
      assert Format.session_day(~D[2026-10-07], "en") == "Wed 10/7"
      assert Format.session_day(~D[2026-10-07], nil) == "10/7 週三"
    end

    test "is empty for a missing date" do
      assert Format.session_day(nil, "en") == ""
    end
  end

  describe "month_title/2" do
    test "follows the chat's language" do
      assert Format.month_title(~D[2026-10-01], "zh-TW") == "2026年10月"
      assert Format.month_title(~D[2026-10-15], "en") == "October 2026"
    end
  end
end
```

---

### Task 2 — client_behaviour.ex

```elixir
defmodule Ganesha.Line.ClientBehaviour do
  @moduledoc "Contract shared by `Ganesha.Line.Client` and `Ganesha.Line.Client.Mock`."

  @callback reply(reply_token :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback push(to :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback loading(chat_id :: String.t(), seconds :: pos_integer()) :: :ok | {:error, term()}
  @callback validate_reply(messages :: [map()]) :: :ok | {:error, term()}
  @callback get_group_member(group_id :: String.t(), user_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
```

---

### Task 2 — client.ex

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

  @doc "Shows LINE's loading animation in a 1:1 chat while the assistant thinks (spec §6.1)."
  @impl true
  def loading(chat_id, seconds) when is_integer(seconds) and seconds > 0 do
    post("/v2/bot/chat/loading/start", %{chatId: chat_id, loadingSeconds: seconds})
  end

  @doc """
  Asks LINE whether `messages` would be accepted as a reply, without sending
  anything to anyone (spec §8, `mix line.validate_cards`).
  """
  @impl true
  def validate_reply(messages) when is_list(messages) do
    post("/v2/bot/message/validate/reply", %{messages: messages})
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

  @doc "A plain text message. Drafts are confirmed from their Flex card (`Ganesha.Line.Cards`)."
  def text_message(text), do: %{type: "text", text: text}

  @doc "A Flex message holding one bubble or carousel; LINE caps `altText` at 400 characters."
  def flex_message(alt_text, contents) when is_binary(alt_text) and is_map(contents) do
    %{type: "flex", altText: String.slice(alt_text, 0, 400), contents: contents}
  end

  defp quick_reply_item(label, data),
    do: %{type: "action", action: %{type: "postback", label: label, data: data}}

  @doc "First-contact language picker for 1:1 chats."
  def language_picker_message do
    %{
      type: "text",
      text: "請選擇語言 / Please choose your language:",
      quickReply: %{
        items: [
          quick_reply_item("繁體中文", "action=set_locale&locale=zh-TW"),
          quick_reply_item("English", "action=set_locale&locale=en")
        ]
      }
    }
  end
end
```

---

### Task 2 — mock.ex

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
  def loading(chat_id, seconds) do
    record(:loading, {chat_id, seconds})
    :ok
  end

  @impl true
  def validate_reply(messages) do
    record(:validate_reply, messages)
    :ok
  end

  @impl true
  def get_group_member(_group_id, _user_id), do: {:ok, %{"displayName" => "測試學生"}}

  def calls, do: Process.get(:line_client_mock_calls, []) |> Enum.reverse()

  defp record(kind, payload) do
    Process.put(:line_client_mock_calls, [
      {kind, payload} | Process.get(:line_client_mock_calls, [])
    ])
  end
end
```

---

### Task 2 — client_test.exs

```elixir
defmodule Ganesha.Line.ClientTest do
  use ExUnit.Case, async: true
  alias Ganesha.Line.Client

  test "text_message/1 builds a plain text message" do
    assert Client.text_message("嗨") == %{type: "text", text: "嗨"}
  end

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

  test "validate_reply/1 asks LINE to check the messages without sending them" do
    parent = self()
    messages = [Client.text_message("嗨")]

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
    end)

    assert :ok = Client.validate_reply(messages)

    assert_receive {:request, "POST", "/v2/bot/message/validate/reply",
                    %{"messages" => [%{"type" => "text", "text" => "嗨"}]} = body}

    refute Map.has_key?(body, "replyToken")
  end

  test "validate_reply/1 returns LINE's reason for an invalid message" do
    reason = %{"message" => "A message (messages[0]) in the request body is invalid"}

    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(reason)
    end)

    assert {:error, {400, ^reason}} = Client.validate_reply([%{type: "text", text: ""}])
  end

  test "flex_message/2 wraps the contents and cuts altText to 400 characters" do
    message = Client.flex_message(String.duplicate("字", 450), %{type: "bubble"})

    assert %{type: "flex", contents: %{type: "bubble"}} = message
    assert String.length(message.altText) == 400
  end
end
```

---

### Task 3 — labels.ex

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
    welcome: {"好的！有什麼需要我幫忙的？", "Thanks! How can I help you today?"},
    # Lookup cards (slice 2)
    card_session: {"課堂", "Session"},
    card_month: {"課表", "Schedule"},
    card_money: {"收支", "Money"},
    card_student: {"學生", "Student"},
    card_credits: {"補課券", "Credits"},
    more_rows: {"…還有 %{count} 筆", "… and %{count} more"},
    cancelled: {"已取消", "Cancelled"},
    roster_count: {"名單 %{count} 人", "Roster: %{count}"},
    no_one_booked: {"還沒有人報名", "No one booked yet"},
    no_show: {"缺席", "No-show"},
    kind_enrolled: {"月課程", "Monthly"},
    kind_makeup: {"補課", "Makeup"},
    kind_drop_in: {"單堂", "Drop-in"},
    kind_trial: {"體驗", "Trial"},
    schedule_title: {"%{month} 課表", "%{month} schedule"},
    sessions_count: {"共 %{count} 堂", "%{count} sessions"},
    booked_count: {"%{count} 人", "%{count} booked"},
    no_sessions: {"這個月還沒有課堂", "No sessions this month"},
    money_title: {"%{month} 收支", "%{month} money"},
    revenue: {"本月收入", "Revenue"},
    tax_threshold: {"營業稅起徵點", "Tax threshold"},
    tax_warn: {"已接近起徵點", "Close to the tax threshold"},
    owed_total: {"未收款 %{amount}", "Owed: %{amount}"},
    nothing_owed: {"沒有人欠款", "Nobody owes anything"},
    owes: {"尚欠 %{amount}", "Owes %{amount}"},
    paid_up: {"已付清", "Paid up"},
    purchases: {"購買紀錄", "Purchases"},
    paid_of: {"已付 %{paid} / %{payable}", "Paid %{paid} of %{payable}"},
    upcoming: {"接下來的課", "Coming up"},
    credits_heading: {"補課券 %{count} 張", "Credits: %{count}"},
    source_package: {"方案補課券", "Package credit"},
    source_cancellation: {"停課補課券", "Cancelled-class credit"},
    expires_on: {"%{date} 到期", "Expires %{date}"},
    no_expiry: {"不會過期", "No expiry"},
    credits_title: {"未使用的補課券", "Open credits"},
    credits_count:
      {"共 %{count} 張，%{expiring} 張本月到期", "%{count} open, %{expiring} expire this month"},
    no_credits: {"沒有未使用的補課券", "No open credits"}
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

---

### Task 3 — labels_test.exs

```elixir
defmodule Ganesha.Line.LabelsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Line.Labels

  @keys ~w(confirm discard open_web more_drafts choose draft pending options confirmed discarded
           failed already_handled replaced not_found exception tag_confirmed tag_discarded
           tag_failed tag_already_handled tag_replaced tag_exception apology unknown_action
           welcome card_session card_month card_money card_student card_credits more_rows
           cancelled roster_count no_one_booked no_show kind_enrolled kind_makeup kind_drop_in
           kind_trial schedule_title sessions_count booked_count no_sessions money_title revenue
           tax_threshold tax_warn owed_total nothing_owed owes paid_up purchases paid_of upcoming
           credits_heading source_package source_cancellation expires_on no_expiry credits_title
           credits_count no_credits)a

  test "every label speaks both languages, and they differ" do
    for key <- @keys do
      zh = Labels.t(key, "zh-TW")
      en = Labels.t(key, "en")

      assert is_binary(zh) and zh != "", "#{key} has no zh-TW label"
      assert is_binary(en) and en != "", "#{key} has no en label"
      assert zh != en, "#{key} is not translated"
    end
  end

  test "any locale other than en gets Traditional Chinese" do
    for key <- @keys, locale <- [nil, "ja", "zh-TW"] do
      assert Labels.t(key, locale) == Labels.t(key, "zh-TW")
    end
  end

  test "fills in an outcome's details" do
    for locale <- ["zh-TW", "en"] do
      text = Labels.t(:failed, locale, title: "收款 Amy NT$3,200", reason: "missing_purchase_id")

      assert text =~ "收款 Amy NT$3,200"
      assert text =~ "missing_purchase_id"
      refute text =~ "%{"
    end

    assert Labels.t(:more_drafts, "en", count: 3) =~ "3"
  end
end
```

---

### Task 4 — lookup.ex

```elixir
defmodule Ganesha.Assistant.Tasks.Lookup do
  @moduledoc false

  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  def session_payload(session, roster, locale) do
    %{
      "title" => session_title(session, locale),
      "style" => session.style,
      "count" => length(roster),
      "cancelled" => session.state == "cancelled",
      "attendees" => Enum.map(roster, &attendee_payload/1)
    }
  end

  def session_data(session, roster, ctx) do
    title = session_title(session, ctx.locale)
    names = Enum.map_join(roster, ", ", & &1.student.display_name)

    base =
      "Session #{session.id}: #{title}, #{length(roster)} booked" <>
        if(session.state == "cancelled", do: " (cancelled)", else: "")

    if names == "", do: base, else: base <> ". #{names}"
  end

  def session_title(session, locale) do
    day = Format.session_day(session.date, locale)
    label = Fmt.session_label(session)
    time = Fmt.session_time_range(session)
    Enum.join([day, label, time], " ")
  end

  def attendee_payload(attendance) do
    %{
      "name" => attendance.student.display_name,
      "kind" => attendance.kind,
      "no_show" => attendance.state == "no_show"
    }
  end

  def parse_month(nil, today), do: Date.beginning_of_month(today)

  def parse_month(text, _today) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> Date.beginning_of_month(date)
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  def parse_month(_other, _today), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  def fetch_student(id) when is_integer(id) do
    case Ganesha.People.get_student(id) do
      nil -> {:error, "no student with id #{id}; use a student id from the snapshot"}
      student -> {:ok, student}
    end
  end

  def fetch_student(_id), do: {:error, "student_id must be a student id from the snapshot"}

  def fetch_session(id) when is_integer(id) do
    case Ganesha.Studio.get_session(id) do
      nil -> {:error, "no session with id #{id}; use a session id from the snapshot"}
      session -> {:ok, session}
    end
  end

  def fetch_session(_id), do: {:error, "session_id must be a session id from the snapshot"}
end
```

---

### Task 5 — cards.ex

```elixir
defmodule Ganesha.Line.Cards do
  @moduledoc """
  The fixed LINE card designs (spec §2 rule 6, §6.2). The model picks a card;
  this module lays it out from stored values only.
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Draft, Format}
  alias Ganesha.Line.Labels

  @max_bubbles 12
  @max_month_rows 10
  @max_credits_rows 10

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

  def render({:session, payload}, locale) when is_map(payload) do
    title = payload["title"] || Labels.t(:card_session, locale)
    lines = session_lines(payload, locale)

    %{
      type: "bubble",
      header: header(title),
      body: body_box(lines)
    }
  end

  def render({:month, payload}, locale) when is_map(payload) do
    month = payload["month"] || ""
    title = Labels.t(:schedule_title, locale, month: month)
    count = payload["session_count"] || 0
    lines = month_lines(payload, locale)

    %{
      type: "bubble",
      header: header(title),
      body: body_box([Labels.t(:sessions_count, locale, count: count) | lines])
    }
  end

  def render({:money, payload}, locale) when is_map(payload) do
    month = payload["month"] || ""
    title = Labels.t(:money_title, locale, month: month)
    lines = money_lines(payload, locale)

    %{
      type: "bubble",
      header: header(title),
      body: body_box(lines)
    }
  end

  def render({:student, payload}, locale) when is_map(payload) do
    name = payload["name"] || "?"
    title = "#{Labels.t(:card_student, locale)} #{name}"
    lines = student_lines(payload, locale)

    %{
      type: "bubble",
      header: header(title),
      body: body_box(lines)
    }
  end

  def render({:credits, payload}, locale) when is_map(payload) do
    title = Labels.t(:credits_title, locale)
    lines = credits_lines(payload, locale)

    %{
      type: "bubble",
      header: header(title),
      body: body_box(lines)
    }
  end

  @spec history_line(Ganesha.Assistant.Task.card(), String.t()) :: String.t()
  def history_line({:draft, %Draft{} = draft}, locale) do
    title = Assistant.describe_draft(draft, locale).title
    "[#{Labels.t(:draft, locale)} ##{draft.id} #{Labels.t(:pending, locale)}] #{title}"
  end

  def history_line({:session, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_session, locale)}] #{payload["title"] || "?"}"
  end

  def history_line({:month, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_month, locale)}] #{payload["month"] || "?"}"
  end

  def history_line({:money, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_money, locale)}] #{payload["month"] || "?"}"
  end

  def history_line({:student, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_student, locale)}] #{payload["name"] || "?"}"
  end

  def history_line({:credits, payload}, locale) when is_map(payload) do
    count = payload["count"] || 0
    "[#{Labels.t(:card_credits, locale)}] #{count}"
  end

  @spec draft_carousel([Draft.t()], String.t()) :: map()
  def draft_carousel(drafts, locale) do
    %{
      type: "carousel",
      contents: drafts |> Enum.take(@max_bubbles) |> Enum.map(&render({:draft, &1}, locale))
    }
  end

  @doc "Sample cards for `mix line.validate_cards` (spec §8)."
  @spec samples(String.t()) :: [Ganesha.Assistant.Task.card()]
  def samples(locale) do
    month = Format.month_title(~D[2026-10-01], locale)

    [
      {:session,
       %{
         "title" => "10/7 週三 基礎 19:00–20:15",
         "style" => "Hatha",
         "count" => 2,
         "cancelled" => false,
         "attendees" => [
           %{"name" => "Lulu", "kind" => "enrolled", "no_show" => false},
           %{"name" => "Amy", "kind" => "drop_in", "no_show" => true}
         ]
       }},
      {:month,
       %{
         "month" => month,
         "session_count" => 2,
         "rows" => [
           %{"day" => "10/7 週三", "label" => "基礎", "time" => "19:00", "count" => 2},
           %{"day" => "10/14 週三", "label" => "基礎", "time" => "19:00", "count" => 1}
         ]
       }},
      {:money,
       %{
         "month" => month,
         "revenue" => "NT$48,000",
         "tax_warn" => true,
         "owed_total" => "NT$3,200",
         "debtors" => [%{"name" => "Amy", "amount" => "NT$3,200"}]
       }},
      {:student,
       %{
         "name" => "Lulu",
         "owed" => "NT$0",
         "purchases" => [
           %{"package" => "月課程", "paid" => "NT$3,200", "payable" => "NT$3,200"}
         ],
         "upcoming" => [%{"day" => "10/7 週三", "label" => "基礎"}],
         "credits" => 1
       }},
      {:credits,
       %{
         "count" => 2,
         "expiring_count" => 1,
         "rows" => [
           %{"student" => "Lulu", "source" => "package", "expires" => "10/31"},
           %{"student" => "Amy", "source" => "cancellation", "expires" => nil}
         ]
       }},
      {:draft,
       %Draft{
         id: 1,
         kind: "record_payment",
         state: "pending",
         parsed: %{
           "student_id" => 1,
           "student_name" => "Lulu",
           "amount" => 3200,
           "method" => "line_pay",
           "paid_on" => "2026-10-02",
           "package_name" => "月課程",
           "before_owed" => 3200
         }
       }}
    ]
  end

  defp session_lines(payload, locale) do
    style = payload["style"]
    count = payload["count"] || 0

    lines =
      [
        if(style, do: style),
        Labels.t(:roster_count, locale, count: count),
        if(payload["cancelled"], do: Labels.t(:cancelled, locale))
      ]
      |> Enum.reject(&is_nil/1)

    attendees = payload["attendees"] || []

    if attendees == [] do
      lines ++ [Labels.t(:no_one_booked, locale)]
    else
      lines ++ Enum.map(attendees, &attendee_line(&1, locale))
    end
  end

  defp attendee_line(%{"name" => name, "kind" => kind, "no_show" => no_show?}, locale) do
    kind_label = kind_label(kind, locale)
    suffix = if(no_show?, do: " (#{Labels.t(:no_show, locale)})", else: "")
    "#{name} · #{kind_label}#{suffix}"
  end

  defp attendee_line(%{"name" => name}, _locale), do: name

  defp month_lines(payload, locale) do
    rows = payload["rows"] || []

    if rows == [] do
      [Labels.t(:no_sessions, locale)]
    else
      shown = Enum.take(rows, @max_month_rows)
      hidden = length(rows) - length(shown)

      Enum.map(shown, fn row ->
        day = row["day"] || "?"
        label = row["label"] || ""
        time = row["time"] || ""
        count = row["count"] || 0
        "#{day} #{label} #{time} · #{Labels.t(:booked_count, locale, count: count)}"
      end) ++ more_rows(hidden, locale)
    end
  end

  defp money_lines(payload, locale) do
    revenue = payload["revenue"] || Format.money(0)
    owed_total = payload["owed_total"] || Format.money(0)

    debtors = payload["debtors"] || []

    debtor_lines =
      if debtors == [] do
        [Labels.t(:nothing_owed, locale)]
      else
        [
          Labels.t(:owed_total, locale, amount: owed_total)
          | Enum.map(debtors, fn d ->
              "#{d["name"]}: #{d["amount"]}"
            end)
        ]
      end

    tax_line =
      if payload["tax_warn"],
        do: ["#{Labels.t(:tax_threshold, locale)}: #{Labels.t(:tax_warn, locale)}"],
        else: []

    ["#{Labels.t(:revenue, locale)}: #{revenue}"] ++ tax_line ++ debtor_lines
  end

  defp student_lines(payload, locale) do
    owed = payload["owed"] || Format.money(0)

    owed_line =
      if owed == Format.money(0) do
        Labels.t(:paid_up, locale)
      else
        Labels.t(:owes, locale, amount: owed)
      end

    purchase_lines =
      case payload["purchases"] || [] do
        [] ->
          []

        purchases ->
          [
            Labels.t(:purchases, locale)
            | Enum.map(purchases, fn p ->
                "#{p["package"]}: #{Labels.t(:paid_of, locale, paid: p["paid"], payable: p["payable"])}"
              end)
          ]
      end

    upcoming_lines =
      case payload["upcoming"] || [] do
        [] ->
          []

        upcoming ->
          [
            Labels.t(:upcoming, locale)
            | Enum.map(upcoming, fn u -> "#{u["day"]} #{u["label"]}" end)
          ]
      end

    credits = payload["credits"] || 0

    credits_line =
      if credits > 0,
        do: [Labels.t(:credits_heading, locale, count: credits)],
        else: []

    [owed_line] ++ purchase_lines ++ upcoming_lines ++ credits_line
  end

  defp credits_lines(payload, locale) do
    count = payload["count"] || 0
    expiring = payload["expiring_count"] || 0
    rows = payload["rows"] || []

    if count == 0 do
      [Labels.t(:no_credits, locale)]
    else
      summary = Labels.t(:credits_count, locale, count: count, expiring: expiring)
      shown = Enum.take(rows, @max_credits_rows)
      hidden = length(rows) - length(shown)

      [summary] ++ Enum.map(shown, &credit_row(&1, locale)) ++ more_rows(hidden, locale)
    end
  end

  defp credit_row(%{"student" => student, "source" => source, "expires" => expires}, locale) do
    source_label =
      case source do
        "package" -> Labels.t(:source_package, locale)
        "cancellation" -> Labels.t(:source_cancellation, locale)
        other -> other
      end

    expiry =
      case expires do
        nil -> Labels.t(:no_expiry, locale)
        date -> Labels.t(:expires_on, locale, date: date)
      end

    "#{student} · #{source_label} · #{expiry}"
  end

  defp more_rows(0, _locale), do: []
  defp more_rows(n, locale) when n > 0, do: [Labels.t(:more_rows, locale, count: n)]

  defp kind_label("enrolled", locale), do: Labels.t(:kind_enrolled, locale)
  defp kind_label("makeup", locale), do: Labels.t(:kind_makeup, locale)
  defp kind_label("drop_in", locale), do: Labels.t(:kind_drop_in, locale)
  defp kind_label("trial", locale), do: Labels.t(:kind_trial, locale)
  defp kind_label(other, _locale), do: other

  defp header(title), do: %{type: "box", layout: "vertical", contents: [text(title, bold: true)]}

  defp body_box(lines) do
    %{
      type: "box",
      layout: "vertical",
      spacing: "sm",
      contents: Enum.map(lines, &text/1)
    }
  end

  defp text(line, opts \\ []) do
    %{
      type: "text",
      text: line,
      size: "sm",
      wrap: true,
      weight: if(Keyword.get(opts, :bold), do: "bold", else: "regular")
    }
  end

  defp change_line({label, nil, after_value}), do: "#{label}: #{after_value}"
  defp change_line({label, before, after_value}), do: "#{label}: #{before} → #{after_value}"

  defp put_body(bubble, []), do: bubble

  defp put_body(bubble, lines) do
    Map.put(bubble, :body, body_box(lines))
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

---

### Task 5 — cards_test.exs

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

  test "a month card truncates long schedules and names how many rows were dropped" do
    rows =
      for n <- 1..12, do: %{"day" => "10/#{n}", "label" => "基礎", "time" => "19:00", "count" => 1}

    bubble =
      Cards.render(
        {:month, %{"month" => "2026年10月", "session_count" => 12, "rows" => rows}},
        "zh-TW"
      )

    texts = Enum.map(bubble.body.contents, & &1.text)
    assert Enum.count(texts, &String.starts_with?(&1, "10/")) == 10
    assert Enum.any?(texts, &String.contains?(&1, "2"))
  end

  test "every sample card renders a bubble with non-empty text lines" do
    for card <- Cards.samples("zh-TW"), {type, _} = card, type != :draft do
      bubble = Cards.render(card, "zh-TW")
      texts = Enum.map(bubble.body.contents, & &1.text)
      refute texts == []
      assert Enum.all?(texts, &(&1 != ""))
    end
  end
end
```

---

### Task 6 — next_session.ex

```elixir
defmodule Ganesha.Assistant.Tasks.NextSession do
  @moduledoc """
  `next_session` (spec §3.1 #1): today's or the next Session and who is coming.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Roster, Studio}
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "next_session"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Look up today's or the next scheduled Session and who is booked. Use show_card \
      when she should see the roster as a card.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, ctx) do
    case Studio.next_session() do
      nil ->
        {:error, "no scheduled session from today onward"}

      session ->
        roster = Roster.list_for_session(session)
        payload = Lookup.session_payload(session, roster, ctx.locale)

        {:ok,
         %{
           data: Lookup.session_data(session, roster, ctx),
           card: {:session, payload}
         }}
    end
  end
end
```

---

### Task 6 — session_roster.ex

```elixir
defmodule Ganesha.Assistant.Tasks.SessionRoster do
  @moduledoc """
  `session_roster` (spec §3.1 #3): one Session's roster.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Roster
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "session_roster"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Look up who is booked in one Session. Pass session_id from the snapshot. \
      Use show_card to show the roster card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{session_id: %{type: "integer"}},
        required: ["session_id"]
      }
    }
  end

  @impl true
  def answer(%{"session_id" => session_id}, ctx) do
    with {:ok, session} <- Lookup.fetch_session(session_id),
         roster <- Roster.list_for_session(session) do
      payload = Lookup.session_payload(session, roster, ctx.locale)

      {:ok,
       %{
         data: Lookup.session_data(session, roster, ctx),
         card: {:session, payload}
       }}
    end
  end

  def answer(_input, _ctx), do: {:error, "session_id must be a session id from the snapshot"}
end
```

---

### Task 6 — next_session_test.exs

```elixir
defmodule Ganesha.Assistant.Tasks.NextSessionTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, People, Studio}
  alias Ganesha.Assistant.Tasks.NextSession
  alias Ganesha.Enrolling

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

    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, package} =
      Ganesha.Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} = Enrolling.add_one_off(session, student, package, [])

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      session: session,
      student: student
    }
  end

  test "returns the next session and a session card payload", c do
    assert {:ok, %{data: data, card: {:session, payload}}} = NextSession.answer(%{}, c.ctx)

    assert data =~ "Session #{c.session.id}"
    assert data =~ "Lulu"
    assert payload["count"] == 1
    assert hd(payload["attendees"])["name"] == "Lulu"
  end

  test "errors when nothing is scheduled from today", c do
    import Ecto.Query

    alias Ganesha.Repo
    alias Ganesha.Roster.Attendance
    alias Ganesha.Studio.Session

    Repo.delete_all(from(a in Attendance, where: a.session_id == ^c.session.id))
    Repo.delete_all(from(s in Session, where: s.id == ^c.session.id))

    assert {:error, message} = NextSession.answer(%{}, c.ctx)
    assert message =~ "no scheduled session"
  end
end
```

---

### Task 7 — month_schedule.ex

```elixir
defmodule Ganesha.Assistant.Tasks.MonthSchedule do
  @moduledoc """
  `month_schedule` (spec §3.1 #2): a month's Sessions with headcounts.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Roster, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "month_schedule"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      List every Session in a calendar month with how many students are booked. \
      Omit month to use the month of today (Taipei). Use show_card for the schedule card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{
            type: "string",
            description: "First day of the month as ISO 8601, e.g. 2026-10-01"
          }
        }
      }
    }
  end

  @impl true
  def answer(input, ctx) do
    case parse_month(input["month"], ctx.today) do
      {:error, text} ->
        {:error, text}

      month ->
        answer_month(month, ctx)
    end
  end

  defp answer_month(month, ctx) do
    sessions = Studio.sessions_in_month(month)
    counts = Roster.count_by_session(Enum.map(sessions, & &1.id))

    rows =
      Enum.map(sessions, fn session ->
        %{
          "day" => Format.session_day(session.date, ctx.locale),
          "label" => Fmt.session_label(session),
          "time" => Fmt.session_time_range(session) |> String.split("–") |> List.first(),
          "count" => Map.get(counts, session.id, 0)
        }
      end)

    month_label = Format.month_title(month, ctx.locale)

    payload = %{
      "month" => month_label,
      "session_count" => length(sessions),
      "rows" => rows
    }

    data =
      "#{month_label}: #{length(sessions)} sessions. " <>
        Enum.map_join(Enum.take(rows, 5), "; ", fn row ->
          "#{row["day"]} #{row["label"]} (#{row["count"]})"
        end)

    {:ok, %{data: data, card: {:month, payload}}}
  end

  defp parse_month(month, today) do
    case Lookup.parse_month(month, today) do
      {:error, text} -> {:error, text}
      %Date{} = date -> date
    end
  end
end
```

---

### Task 7 — student_summary.ex

```elixir
defmodule Ganesha.Assistant.Tasks.StudentSummary do
  @moduledoc """
  `student_summary` (spec §3.1 #4): owed, purchases, upcoming Sessions, open Credits.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Reporting, Roster, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "student_summary"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Summarize one student: what they owe, their purchases and payments, upcoming \
      Sessions, and open makeup Credits. Use show_card for the summary card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{student_id: %{type: "integer"}},
        required: ["student_id"]
      }
    }
  end

  @impl true
  def answer(%{"student_id" => student_id}, ctx) do
    with {:ok, student} <- Lookup.fetch_student(student_id) do
      owed = Reporting.outstanding_for_student(student.id)

      purchases =
        Sales.list_purchases_for_student(student.id)
        |> Enum.map(fn purchase ->
          paid = Sales.confirmed_paid(purchase.id)
          payable = Sales.payable(purchase)

          %{
            "package" => purchase.package.name,
            "paid" => Format.money(paid),
            "payable" => Format.money(payable)
          }
        end)

      upcoming =
        student.id
        |> Roster.list_for_student()
        |> Enum.filter(fn a -> Date.compare(a.session.date, ctx.today) != :lt end)
        |> Enum.take(5)
        |> Enum.map(fn a ->
          %{
            "day" => Format.session_day(a.session.date, ctx.locale),
            "label" => Fmt.session_label(a.session)
          }
        end)

      credits = Roster.available_credits(student.id, ctx.today)

      payload = %{
        "name" => student.display_name,
        "owed" => Format.money(owed),
        "purchases" => purchases,
        "upcoming" => upcoming,
        "credits" => length(credits)
      }

      data =
        "#{student.display_name} (id #{student.id}): owes #{Format.money(owed)}, " <>
          "#{length(purchases)} purchase(s), #{length(credits)} open credit(s)"

      {:ok, %{data: data, card: {:student, payload}}}
    end
  end

  def answer(_input, _ctx), do: {:error, "student_id must be a student id from the snapshot"}
end
```

---

### Task 7 — month_money.ex

```elixir
defmodule Ganesha.Assistant.Tasks.MonthMoney do
  @moduledoc """
  `month_money` (spec §3.1 #5): revenue, who owes, tax threshold for a month.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Reporting
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "month_money"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Revenue collected in a month, every student who still owes money, and how close \
      the month is to the tax registration threshold. Omit month for the current month. \
      Use show_card for the money card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{type: "string", description: "ISO 8601 date in that month, e.g. 2026-10-01"}
        }
      }
    }
  end

  @impl true
  def answer(input, ctx) do
    case parse_month(input["month"], ctx.today) do
      {:error, text} ->
        {:error, text}

      month ->
        answer_month(month, ctx)
    end
  end

  defp answer_month(month, ctx) do
    revenue = Reporting.revenue_for_month(month)
    tax = Reporting.tax_threshold_status(month)

    owing = Reporting.outstanding_by_student()

    debtors =
      Enum.map(owing, fn %{student: student, outstanding: amount} ->
        %{"name" => student.display_name, "amount" => Format.money(amount)}
      end)

    owed_total = Enum.sum(Enum.map(owing, & &1.outstanding))

    month_label = Format.month_title(month, ctx.locale)

    payload = %{
      "month" => month_label,
      "revenue" => Format.money(revenue),
      "tax_warn" => tax.warn?,
      "owed_total" => Format.money(owed_total),
      "debtors" => debtors
    }

    data =
      "#{month_label}: revenue #{Format.money(revenue)}, " <>
        "#{length(debtors)} student(s) owe #{Format.money(owed_total)}" <>
        if(tax.warn?, do: "; close to tax threshold", else: "")

    {:ok, %{data: data, card: {:money, payload}}}
  end

  defp parse_month(month, today) do
    case Lookup.parse_month(month, today) do
      {:error, text} -> {:error, text}
      %Date{} = date -> date
    end
  end
end
```

---

### Task 7 — open_credits.ex

```elixir
defmodule Ganesha.Assistant.Tasks.OpenCredits do
  @moduledoc """
  `open_credits` (spec §3.1 #6): open and expiring makeup Credits.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Reporting
  alias Ganesha.Assistant.Format

  @impl true
  def name, do: "open_credits"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Every unspent makeup Credit in the studio, soonest expiry first. Use show_card \
      for the credits card.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, ctx) do
    credits = Reporting.open_credits(ctx.today)
    month_end = Date.end_of_month(ctx.today)

    expiring =
      Enum.count(credits, fn c ->
        c.expires_on && Date.compare(c.expires_on, month_end) != :gt &&
          Date.compare(c.expires_on, ctx.today) != :lt
      end)

    rows =
      Enum.map(credits, fn credit ->
        %{
          "student" => credit.student.display_name,
          "source" => credit.source,
          "expires" =>
            if(credit.expires_on,
              do: Format.session_day(credit.expires_on, ctx.locale),
              else: nil
            )
        }
      end)

    payload = %{
      "count" => length(credits),
      "expiring_count" => expiring,
      "rows" => rows
    }

    data =
      "#{length(credits)} open credit(s)" <>
        if(expiring > 0, do: ", #{expiring} expiring this month", else: "")

    {:ok, %{data: data, card: {:credits, payload}}}
  end
end
```

---

### Task 8 — tasks.ex

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
    MonthMoney,
    MonthSchedule,
    NextSession,
    OpenCredits,
    RecordPayment,
    SessionRoster,
    SetLanguage,
    StudentSummary
  }

  @questions [
    NextSession,
    MonthSchedule,
    SessionRoster,
    StudentSummary,
    MonthMoney,
    OpenCredits
  ]

  @teacher @questions ++ [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage]
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

---

### Task 8 — tasks_test.exs

```elixir
defmodule Ganesha.Assistant.TasksTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Tasks

  alias Ganesha.Assistant.Tasks.{
    AskTeacher,
    BookOneOff,
    MakeupRequest,
    MonthMoney,
    MonthSchedule,
    NextSession,
    OpenCredits,
    RecordPayment,
    SessionRoster,
    SetLanguage,
    StudentSummary
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

    teacher = Tasks.for_chat(:teacher)

    for task <- [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage] do
      assert task in teacher
    end
  end

  test "the six questions are Teacher chat lookups only" do
    teacher = Tasks.for_chat(:teacher)
    group = Tasks.for_chat(:group)
    student = Tasks.for_chat(:student)

    for task <- [
          NextSession,
          MonthSchedule,
          SessionRoster,
          StudentSummary,
          MonthMoney,
          OpenCredits
        ] do
      assert task in teacher
      refute task in group
      refute task in student
      assert task.kind() == :lookup
    end
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

---

### Task 9 — line.validate_cards.ex

```elixir
defmodule Mix.Tasks.Line.ValidateCards do
  @shortdoc "Validate every LINE card shape against the Messaging API (spec §8)"

  @moduledoc """
  Builds one of every card type from in-memory sample data and POSTs each to
  LINE's `/v2/bot/message/validate/reply` with the configured channel token.
  Nothing is sent to users. Exits non-zero when any card fails.

      source .env.dev && mix line.validate_cards
  """

  use Mix.Task

  alias Ganesha.Line.{Cards, Client}

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    locales = ["zh-TW", "en"]
    failures = []

    failures =
      Enum.reduce(locales, failures, fn locale, acc ->
        acc ++ validate_locale(locale)
      end)

    choices =
      Client.text_message("x")
      |> Map.put(:quickReply, %{
        items: [
          %{type: "action", action: %{type: "message", label: "A", text: "A"}},
          %{type: "action", action: %{type: "message", label: "B", text: "B"}}
        ]
      })

    failures =
      case Client.validate_reply([choices]) do
        :ok ->
          IO.puts("PASS  choices-only reply")
          failures

        {:error, reason} ->
          failures ++ [{"choices-only reply", reason}]
      end

    if failures == [] do
      IO.puts("All cards passed validation.")
    else
      Enum.each(failures, fn {name, reason} ->
        IO.puts(:stderr, "FAIL  #{name}: #{inspect(reason)}")
      end)

      System.halt(1)
    end
  end

  defp validate_locale(locale) do
    Cards.samples(locale)
    |> Enum.flat_map(fn card ->
      name = elem(card, 0)

      cond do
        name == :draft ->
          carousel = Client.flex_message("drafts", Cards.draft_carousel([elem(card, 1)], locale))
          validate("#{locale} draft carousel", [carousel])

        true ->
          bubble = Cards.render(card, locale)
          alt = Cards.history_line(card, locale)
          flex = Client.flex_message(alt, bubble)
          validate("#{locale} #{name}", [flex])
      end
    end)
  end

  defp validate(label, messages) do
    case Client.validate_reply(messages) do
      :ok ->
        IO.puts("PASS  #{label}")
        []

      {:error, reason} ->
        [{label, reason}]
    end
  end
end
```

---

### Task 10 — line_real_questions.exs

```elixir
#!/usr/bin/env elixir
# Real Sonnet 5.5 runs for the six lookup tasks (spec §8, slice 2).
#
#     source .env.dev && mix run priv/scripts/line_real_questions.exs
#
# Uses the dev Anthropic provider and Line.Client.Mock — nothing reaches users.
# For LINE Flex validation against the real API, run `mix line.validate_cards`.

import Ecto.Query

alias Ganesha.{Assistant, Catalog, People, Repo, Sales, Studio}
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

teacher_id = "Usmokequestions00000000000000"

questions = [
  "下一堂課是什麼時候？誰會來？",
  "幫我看這個月的課表",
  "10/7 那堂基礎班的名單給我",
  "SMOKE 小美欠多少？她最近的課和補課券呢？",
  "這個月收入多少？還有誰沒付清？",
  "現在還有哪些補課券沒用？"
]

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

{:ok, slot} =
  Studio.create_slot(%{
    weekday: 3,
    start_time: ~T[19:00:00],
    end_time: ~T[20:15:00],
    default_style: "Hatha",
    label: "基礎"
  })

{:ok, _session} =
  Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

{:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, thread} = Assistant.set_locale(thread, "zh-TW")

for text <- questions do
  {:ok, _} = Assistant.append_message(thread, "user", text, nil)
  IO.puts("\n== Teacher: #{text}")

  case Conversation.run_turn(thread) do
    {:ok, turn} ->
      drafts = Assistant.get_drafts(turn.draft_ids)
      IO.puts("cards: #{length(turn.cards)}, drafts: #{length(drafts)}")
      IO.puts(Reply.history_text(turn, drafts, "zh-TW") || "(no card history)")

    {:error, reason} ->
      cleanup.()
      IO.puts("failed: #{inspect(reason)}")
      System.halt(1)
  end
end

cleanup.()
IO.puts("\nAll question turns completed.")
```

---


### Task 11: Prompts rule 8

Add to `teacher_rules/0` in `lib/ganesha/assistant/prompts.ex` before the closing triple-quote:

    8. When she asks who is coming, the schedule, money owed, or open makeup Credits, call the matching lookup task (next_session, month_schedule, session_roster, student_summary, month_money, open_credits) with show_card true so she gets the card.

### Task 12: Conversation test

- Add `def validate_reply(messages), do: LineMock.validate_reply(messages)` to `ExpiredTokenLine`, `RejectingLine`, and `InterleavingLine` in `conversation_test.exs`.
- Replace exact teacher tool list assert with membership over: `next_session`, `month_schedule`, `session_roster`, `student_summary`, `month_money`, `open_credits`, `record_payment`, `book_one_off`, `makeup_request`, `ask_teacher`, `set_language`.

### Task 13: Smoke Step 7

Copy Step 7 block from `priv/scripts/line_smoke.exs` in this slice (before `# ---------------------------------------------------------------- teardown`): Studio slot+session, webhook event, ProviderMock `next_session` + `show_card`, assert Flex bubble.

### Task 14: Ship

- [ ] `mix precommit`
- [ ] `source .env.dev && mix run priv/scripts/line_real_questions.exs`
- [ ] `source .env.dev && mix line.validate_cards`

## Verification

Plan author: `/tmp/plan-slice-2`, HEAD `a1523b0`, `mix test` → 517 passed.

## Execution Handoff

Subagent-driven (recommended) or `executing-plans`.
