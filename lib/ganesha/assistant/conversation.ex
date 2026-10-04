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

    result = run_turn(thread)
    # The turn may have changed the language (set_language), even if it failed later.
    thread = Assistant.get_thread!(thread.id)
    locale = locale(thread)

    case result do
      {:ok, turn} ->
        drafts = Assistant.get_drafts(turn.draft_ids)
        messages = Reply.build(turn, drafts, locale)

        deliver(reply_token, source_id, messages, fn -> text_only(turn, drafts, locale) end)
        record_cards(turn, Reply.history_text(turn, drafts, locale))

      {:error, reason} ->
        Logger.error(
          "Ganesha.Assistant.Agent.run/4 failed for thread #{thread.id}: #{inspect(reason)}"
        )

        deliver(reply_token, source_id, [Client.text_message(Labels.t(:apology, locale))], nil)
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
    thread = thread_for(source_id, teacher_id)

    case Assistant.set_locale(thread, params["locale"]) do
      {:ok, thread} ->
        if pending_user_turn?(thread) do
          handle_message(thread, reply_token, source_id)
        else
          welcome = Client.text_message(Labels.t(:welcome, thread.locale))
          deliver(reply_token, source_id, [welcome], nil)
        end

      {:error, _reason} ->
        deliver(reply_token, source_id, [Client.language_picker_message()], nil)
    end

    :ok
  end

  # Only the teacher may confirm or discard (spec §6.3).
  def handle_postback(%{"action" => action} = params, reply_token, source_id, teacher_id)
      when action in ["confirm", "discard"] and source_id == teacher_id do
    thread = thread_for(source_id, teacher_id)
    locale = locale(thread)
    {text, history_line} = settle(action, parse_id(params["draft_id"]), locale)

    deliver(reply_token, source_id, [Client.text_message(text)], nil)

    if history_line do
      {:ok, _} = Assistant.append_message(thread, "assistant", history_line, nil)
    end

    :ok
  end

  def handle_postback(_params, reply_token, source_id, teacher_id) do
    locale = source_id |> thread_for(teacher_id) |> locale()
    deliver(reply_token, source_id, [Client.text_message(Labels.t(:unknown_action, locale))], nil)
    :ok
  end

  @doc """
  The 1:1 thread for a LINE user: the Teacher chat when `source_id` is the
  teacher, otherwise that user's Student chat.
  """
  @spec thread_for(String.t(), String.t()) :: Thread.t()
  def thread_for(source_id, teacher_id) do
    source_type = if source_id == teacher_id, do: "teacher", else: "user"
    {:ok, thread} = Assistant.get_or_create_thread(source_type, source_id)
    thread
  end

  @doc """
  Sends `messages` as a reply, which is free. An unusable reply token pushes
  the same messages to `source_id`; LINE rejecting the messages themselves is
  logged and pushes `fallback.()` as one text message, or nothing when
  `fallback` is nil (spec §6.1 step 6, §7).
  """
  @spec deliver(String.t(), String.t(), [map()], (-> String.t()) | nil) :: :ok
  def deliver(_reply_token, _source_id, [], _fallback), do: :ok

  def deliver(reply_token, source_id, messages, fallback) do
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
    title = Assistant.draft_summary(draft, locale)
    {outcome_text(status, draft, title, locale), history_line(status, draft, title, locale)}
  end

  defp outcome_text(:applied, _draft, title, locale),
    do: Labels.t(:confirmed, locale, title: title)

  defp outcome_text(:discarded, _draft, title, locale),
    do: Labels.t(:discarded, locale, title: title)

  defp outcome_text(:failed, draft, title, locale),
    do:
      Labels.t(:failed, locale,
        title: title,
        reason: Labels.failure_reason(draft.failure_reason, locale)
      )

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
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("LINE push also failed: #{inspect(reason)}")
        :ok
    end
  end

  # `turn.text` plus one line per Draft (spec §6.1 step 6).
  defp text_only(turn, drafts, locale) do
    [turn.text | Enum.map(drafts, &Cards.history_line({:draft, &1}, locale))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp record_cards(_turn, nil), do: :ok

  defp record_cards(%Turn{reply_message_id: id}, text) do
    case Assistant.append_to_message(id, text) do
      {:ok, _message} ->
        :ok

      {:error, reason} ->
        Logger.warning("could not record cards on message #{id}: #{inspect(reason)}")
    end
  end

  defp pending_user_turn?(thread) do
    match?(%{role: "user"}, List.last(Assistant.list_messages(thread)))
  end

  defp locale(%Thread{locale: locale}), do: locale || "zh-TW"

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
