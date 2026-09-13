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
