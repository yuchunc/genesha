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
