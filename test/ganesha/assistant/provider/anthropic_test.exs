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

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    messages = [%{role: "user", content: "hi"}]

    assert {:ok, %{text: "哈囉", tool_calls: []}} =
             Anthropic.complete(messages, [], system: "sys", plug: stub)
  end

  test "translates a tool_use response into text + tool_calls" do
    stub = fn conn ->
      body = %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "find_student",
            "input" => %{"query" => "Lulu"}
          }
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    assert {:ok,
            %{
              text: nil,
              tool_calls: [%{id: "toolu_1", name: "find_student", input: %{"query" => "Lulu"}}]
            }} =
             Anthropic.complete([], [], system: "sys", plug: stub)
  end

  test "surfaces a non-200 response as an error" do
    stub = fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end

    assert {:error, {:http_error, 401, "unauthorized"}} =
             Anthropic.complete([], [], system: "sys", plug: stub)
  end

  # `retry-after: 0` keeps Req's retry from sleeping between attempts.
  @tag :capture_log
  test "retries an overloaded POST twice before giving up" do
    attempts = :counters.new(1, [])

    stub = fn conn ->
      :counters.add(attempts, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(503, "overloaded")
    end

    assert {:error, {:http_error, 503, "overloaded"}} =
             Anthropic.complete([], [], system: "sys", plug: stub)

    assert :counters.get(attempts, 1) == 3
  end

  @tag :capture_log
  test "a retry that succeeds returns the completion" do
    attempts = :counters.new(1, [])

    stub = fn conn ->
      :counters.add(attempts, 1, 1)

      if :counters.get(attempts, 1) == 1 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(429, "rate limited")
      else
        body = %{"content" => [%{"type" => "text", "text" => "ok"}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    end

    assert {:ok, %{text: "ok"}} = Anthropic.complete([], [], system: "sys", plug: stub)
    assert :counters.get(attempts, 1) == 2
  end

  test "translates every Agent.to_wire/1 shape into non-empty Anthropic content, even past the retention sweep" do
    parent = self()

    stub = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(raw)})
      body = %{"content" => [%{"type" => "text", "text" => "ok"}]}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    messages = [
      # A group message the Task 18 retention sweep has nulled - must not crash and must not
      # send Anthropic an empty content string.
      %{role: "user", content: nil, tool_calls: []},
      # An assistant turn with no text and no tool calls (e.g. also swept, or a truncated
      # response) - must not send an empty content array, which Anthropic rejects with 400.
      %{role: "assistant", content: nil, tool_calls: []},
      %{role: "tool", content: nil, tool_calls: [%{tool_use_id: "t1", content: "Lulu (#3)"}]}
    ]

    assert {:ok, _} = Anthropic.complete(messages, [], system: "sys", plug: stub)
    assert_receive {:body, %{"messages" => [user, assistant, tool_turn]}}
    assert %{"role" => "user", "content" => content} = user
    assert is_binary(content) and content != ""

    assert %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]} =
             assistant

    assert is_binary(text) and text != ""

    assert %{"role" => "user", "content" => [%{"type" => "tool_result", "tool_use_id" => "t1"}]} =
             tool_turn
  end

  test "collects every text block in a response instead of only the first" do
    stub = fn conn ->
      body = %{
        "content" => [
          %{"type" => "text", "text" => "先查詢中"},
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "find_student",
            "input" => %{"query" => "Lulu"}
          },
          %{"type" => "text", "text" => "查到了"}
        ]
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    assert {:ok, %{text: text}} = Anthropic.complete([], [], system: "sys", plug: stub)
    assert text == "先查詢中\n查到了"
  end

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
end
