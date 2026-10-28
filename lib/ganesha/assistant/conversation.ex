defmodule Ganesha.Assistant.Conversation do
  @moduledoc """
  One 1:1 turn and one postback, end to end (spec §6.1, §6.3), moved out of
  `Ganesha.Assistant.ProcessEventWorker`.

  A turn shows LINE's loading animation, runs the agent with the chat's
  prompt, memory and tasks, packs the `Turn` into LINE messages, replies
  (pushing when there is no reply token or it is unusable, or a text-only
  version when LINE rejects the messages), and appends the cards it sent to
  the model's own reply. Confirm and Discard answer with one text message and
  leave the outcome in the Teacher chat's history; a request card's shortcut
  runs a Teacher-chat turn instead (spec 2026-10-07 §4). An answer on a member
  notice replies with one text message and leaves it in the tapping teacher's
  history as 「[通知回覆] …」, so the model knows what she chose (spec
  2026-10-19-november-launch-design.md §2).
  """

  require Logger

  alias Ganesha.{Assistant, Clock, People, Repo}

  alias Ganesha.Assistant.{
    Agent,
    Draft,
    DraftNotifier,
    MemberNoticeWorker,
    Memory,
    Prompts,
    Snapshot,
    Tasks,
    Thread,
    Turn
  }

  alias Ganesha.Assistant.Tasks.{MakeupRequest, SignupRequest}
  alias Ganesha.Line.{Cards, Client, Labels, Reply}

  @loading_seconds 20

  # Spec 2026-10-07 §4: a request card's shortcut action => its request task.
  @request_actions %{
    "enroll_from_request" => SignupRequest,
    "book_from_request" => MakeupRequest
  }

  # Spec 2026-10-19-november-launch-design.md §2: a teacher's answer on a member notice.
  @member_actions ~w(member_ok member_not_student member_wrong_link member_pick member_new)

  @doc """
  Runs one turn and delivers it. A nil `reply_token` (a re-run after an
  edit) pushes instead of replying (spec 2026-10-07 §6).
  """
  @spec handle_message(Thread.t(), String.t() | nil, String.t()) :: :ok
  def handle_message(%Thread{} = thread, reply_token, source_id) do
    show_loading(source_id)

    result = run_turn(thread)
    # The turn may have changed the language (set_language), even if it failed later.
    thread = Assistant.get_thread!(thread.id)
    locale = locale(thread)

    case result do
      {:ok, turn} ->
        drafts = cards_for(thread, turn)
        messages = Reply.build(turn, drafts, locale)

        deliver(reply_token, source_id, messages, fn -> text_only(turn, drafts, locale) end)
        record_cards(turn, Reply.history_text(turn, drafts, locale))

      {:error, reason} ->
        Logger.error(
          "Ganesha.Assistant.Agent.run/4 failed for thread #{thread.id}: #{inspect(reason)}"
        )

        deliver(reply_token, source_id, [Client.text_message(Labels.t(:apology, locale))], nil)
    end

    # Spec 2026-10-06 §3: covers a plain message and the turn that runs once a
    # newcomer picks a language.
    if thread.source_type == "user", do: DraftNotifier.schedule_if_pending(thread)
    :ok
  end

  @doc """
  Runs the agent for the thread's latest message with the prompt, history and
  tasks its chat gets (spec §6.1, §2 rule 7).
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

  @spec handle_postback(map(), String.t(), String.t()) :: :ok
  def handle_postback(%{"action" => "set_locale"} = params, reply_token, source_id) do
    thread = thread_for(source_id)

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

  # Only a teacher may confirm or discard (spec §6.3); any teacher may settle
  # any Draft, whoever's chat it was proposed in.
  def handle_postback(%{"action" => action} = params, reply_token, source_id)
      when action in ["confirm", "discard"] do
    if Ganesha.Line.teacher?(source_id),
      do: settle_postback(action, params, reply_token, source_id),
      else: unknown_action(reply_token, source_id)
  end

  # Spec 2026-10-07 §4: 「幫他報名」 / 「幫他補課」 hand a pending request to
  # this teacher's own chat as a normal turn. Nothing is confirmed here; the
  # Draft that turn proposes settles the request when she confirms it.
  def handle_postback(%{"action" => action} = params, reply_token, source_id)
      when is_map_key(@request_actions, action) do
    if Ganesha.Line.teacher?(source_id) do
      task = Map.fetch!(@request_actions, action)
      act_on_request(task, parse_id(params["draft_id"]), reply_token, source_id)
    else
      unknown_action(reply_token, source_id)
    end
  end

  def handle_postback(%{"action" => action} = params, reply_token, source_id)
      when action in @member_actions do
    if Ganesha.Line.teacher?(source_id),
      do: answer_member_notice(action, params, reply_token, source_id),
      else: unknown_action(reply_token, source_id)
  end

  def handle_postback(_params, reply_token, source_id), do: unknown_action(reply_token, source_id)

  @doc """
  The 1:1 thread for a LINE user: that teacher's Teacher chat when
  `source_id` is one of the teachers, otherwise that user's Student chat.
  """
  @spec thread_for(String.t()) :: Thread.t()
  def thread_for(source_id) do
    source_type = if Ganesha.Line.teacher?(source_id), do: "teacher", else: "user"
    {:ok, thread} = Assistant.get_or_create_thread(source_type, source_id)
    thread
  end

  defp settle_postback(action, params, reply_token, source_id) do
    thread = thread_for(source_id)
    outcome = settle(action, parse_id(params["draft_id"]), source_id, locale(thread))
    deliver_outcome(thread, reply_token, source_id, outcome)
  end

  defp act_on_request(task, id, reply_token, source_id) do
    thread = thread_for(source_id)
    locale = locale(thread)
    kind = task.name()

    case id && Assistant.get_draft(id) do
      %Draft{kind: ^kind, state: "pending"} = request ->
        message = task.teacher_message(request.id, request.parsed, locale)
        {:ok, _} = Assistant.append_message(thread, "user", message, nil)
        handle_message(thread, reply_token, source_id)

      %Draft{kind: ^kind} = request ->
        outcome = request |> not_pending() |> describe_outcome(locale)
        deliver_outcome(thread, reply_token, source_id, outcome)

      _other ->
        deliver_outcome(thread, reply_token, source_id, {Labels.t(:not_found, locale), nil})
    end
  end

  defp answer_member_notice(
         action,
         %{"uid" => uid, "name" => name} = params,
         reply_token,
         source_id
       )
       when is_binary(uid) and is_binary(name) do
    case member_tap(action, uid, name, params["from"], parse_id(params["sid"])) do
      :malformed ->
        unknown_action(reply_token, source_id)

      result ->
        thread = thread_for(source_id)
        locale = locale(thread)
        text = member_reply(result, name, locale)

        deliver_outcome(
          thread,
          reply_token,
          source_id,
          {text, member_history(result, text, locale)}
        )
    end
  end

  defp answer_member_notice(_action, _params, reply_token, source_id),
    do: unknown_action(reply_token, source_id)

  # 是學生 changes nothing; it only checks the Student still has this LINE id.
  defp member_tap("member_ok", uid, _name, _from, sid) when is_integer(sid) do
    case People.get_student(sid) do
      %{line_user_id: ^uid} = student -> {:ok, {:confirmed, student}}
      _other -> {:error, :already_handled}
    end
  end

  defp member_tap("member_not_student", uid, name, "unsure", _sid),
    do: People.member_not_student(uid, name, "unsure", nil)

  defp member_tap("member_not_student", uid, name, from, sid)
       when from in ["created", "linked"] and is_integer(sid),
       do: People.member_not_student(uid, name, from, sid)

  # The fresh unsure notice is enqueued in the same transaction as the unlink.
  defp member_tap("member_wrong_link", uid, name, _from, sid) when is_integer(sid) do
    Repo.transact(fn ->
      with {:ok, candidates} <- People.member_wrong_link(uid, name, sid) do
        {:ok, _job} =
          {:unsure, candidates}
          |> MemberNoticeWorker.args(uid, name)
          |> MemberNoticeWorker.new()
          |> Oban.insert()

        {:ok, :unlinked}
      end
    end)
  end

  defp member_tap("member_pick", uid, _name, _from, sid) when is_integer(sid) do
    with {:ok, student} <- People.member_pick(uid, sid), do: {:ok, {:linked, student}}
  end

  defp member_tap("member_new", uid, name, _from, _sid) do
    with {:ok, student} <- People.member_new(uid, name), do: {:ok, {:created, student}}
  end

  defp member_tap(_action, _uid, _name, _from, _sid), do: :malformed

  defp member_reply({:ok, {:confirmed, student}}, _line_name, locale),
    do: Labels.t(:member_confirmed, locale, name: student.display_name)

  defp member_reply({:ok, :marked}, line_name, locale),
    do: Labels.t(:member_marked_not_student, locale, line_name: line_name)

  defp member_reply({:ok, {:kept, student}}, line_name, locale),
    do: Labels.t(:member_kept_records, locale, name: student.display_name, line_name: line_name)

  defp member_reply({:ok, :unlinked}, line_name, locale),
    do: Labels.t(:member_unlinked, locale, line_name: line_name)

  defp member_reply({:ok, {:linked, student}}, line_name, locale),
    do: Labels.t(:member_linked, locale, name: student.display_name, line_name: line_name)

  defp member_reply({:ok, {:created, student}}, line_name, locale),
    do: Labels.t(:member_created, locale, name: student.display_name, line_name: line_name)

  defp member_reply({:error, :already_handled}, _line_name, locale),
    do: Labels.t(:member_already_handled, locale)

  # A tap that changed nothing leaves no history.
  defp member_history({:error, :already_handled}, _text, _locale), do: nil

  defp member_history(_result, text, locale),
    do: "[#{Labels.t(:tag_notice_answer, locale)}] #{text}"

  defp deliver_outcome(thread, reply_token, source_id, {text, history_line}) do
    deliver(reply_token, source_id, [Client.text_message(text)], nil)

    if history_line do
      {:ok, _} = Assistant.append_message(thread, "assistant", history_line, nil)
    end

    :ok
  end

  defp unknown_action(reply_token, source_id) do
    locale = source_id |> thread_for() |> locale()
    deliver(reply_token, source_id, [Client.text_message(Labels.t(:unknown_action, locale))], nil)
    :ok
  end

  @doc """
  Sends `messages` as a reply, which is free. A nil `reply_token` pushes
  directly (spec 2026-10-07 §6), and so does an unusable one; LINE rejecting
  the messages themselves is logged and pushes `fallback.()` as one text
  message, or nothing when `fallback` is nil (spec §6.1 step 6, §7).
  """
  @spec deliver(String.t() | nil, String.t(), [map()], (-> String.t()) | nil) :: :ok
  def deliver(_reply_token, _source_id, [], _fallback), do: :ok

  def deliver(nil, source_id, messages, _fallback), do: push(source_id, messages)

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

  defp settle(_action, nil, _source_id, locale), do: {Labels.t(:not_found, locale), nil}

  defp settle(action, id, source_id, locale) do
    case Assistant.get_draft(id) do
      nil -> {Labels.t(:not_found, locale), nil}
      draft -> action |> outcome(draft, source_id) |> describe_outcome(locale)
    end
  end

  # Spec 2026-10-07 §7: `confirmed_by` names the teacher who tapped.
  defp outcome("confirm", draft, source_id) do
    case Assistant.confirm_draft(draft, "line:" <> source_id) do
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

  defp outcome("discard", draft, _source_id) do
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

  # Spec 2026-10-06 §2: a Student chat never sees Draft cards; its Drafts reach
  # the teachers through DraftNotifier instead.
  defp cards_for(%Thread{source_type: "user"}, _turn), do: []
  defp cards_for(_thread, %Turn{draft_ids: ids}), do: Assistant.get_drafts(ids)

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
