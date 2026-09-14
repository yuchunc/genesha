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

  # `content` is nullable (Message.changeset/2 only requires :thread_id and
  # :role), and the Task 18 retention sweep nulls it out on every group
  # message older than 24h while the row stays in replayed history — the
  # Anthropic API also rejects an empty content array/string outright, so
  # every branch below must fall back to a non-empty placeholder rather
  # than ever emit `content: nil` or `content: []`.
  defp to_wire_message(%{role: "user", content: content}) do
    %{role: "user", content: content || "[內容已依保留政策清除]"}
  end

  defp to_wire_message(%{role: "assistant", content: content, tool_calls: tool_calls}) do
    text_blocks = if content in [nil, ""], do: [], else: [%{type: "text", text: content}]

    tool_blocks =
      Enum.map(tool_calls || [], fn call ->
        %{type: "tool_use", id: call.id, name: call.name, input: call.input}
      end)

    blocks =
      case text_blocks ++ tool_blocks do
        [] -> [%{type: "text", text: "[內容已依保留政策清除]"}]
        blocks -> blocks
      end

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
    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])
      |> case do
        "" -> nil
        joined -> joined
      end

    tool_calls =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(&%{id: &1["id"], name: &1["name"], input: &1["input"]})

    %{text: text, tool_calls: tool_calls}
  end
end
