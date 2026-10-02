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
        {:ok, reply} = Assistant.append_message(thread, "assistant", text, nil)
        {:ok, %Turn{turn | text: text, reply_message_id: reply.id}}

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
    replaces = draft_id(input["replaces_draft_id"])

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

  # The model may send the id as a string ("41"); anything that is not a
  # whole id counts as absent.
  defp draft_id(id) when is_integer(id), do: id

  defp draft_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp draft_id(_id), do: nil

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
