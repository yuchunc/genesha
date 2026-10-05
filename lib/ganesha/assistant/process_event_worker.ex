defmodule Ganesha.Assistant.ProcessEventWorker do
  @moduledoc """
  Routes one `line_events` row (spec §6.1). 1:1 text messages go to
  `Ganesha.Assistant.Conversation` once the sender has picked a language (the
  first-contact picker lives here); 1:1 postbacks go to
  `Conversation.handle_postback/4`. Group chat messages run the agent with
  the Group chat's three tasks and are never answered. Unsend and
  messageEdited correct the stored text, discard the message's pending
  Drafts and, in the Teacher chat, drop the digests covering its day. A
  failed agent run is logged, never retried: a retry would
  re-append the message and risk duplicate Drafts for one fact.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Ganesha.{Assistant, Clock, Line, Repo}

  alias Ganesha.Assistant.{
    Agent,
    Conversation,
    GroupDraftNotifier,
    Memory,
    Prompts,
    Snapshot,
    Tasks
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"line_event_id" => line_event_id}}) do
    line_event = Line.get_event!(line_event_id)

    :ok = route(line_event)
    Line.mark_processed(line_event)
    :ok
  end

  defp route(%{source_type: "user", raw_type: "message"} = event) do
    if simple_reply?(),
      do: handle_simple_reply(event),
      else: handle_user_message(event)
  end

  defp route(%{
         source_type: "user",
         raw_type: "postback",
         source_id: source_id,
         payload: %{"replyToken" => reply_token, "postback" => %{"data" => data}}
       }) do
    Conversation.handle_postback(URI.decode_query(data), reply_token, source_id)
  end

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

  defp route(%{raw_type: "unsend"} = event), do: handle_unsend(event)
  defp route(%{raw_type: "messageEdited"} = event), do: handle_message_edited(event)
  defp route(_event), do: :ok

  defp handle_user_message(%{
         payload: %{
           "replyToken" => reply_token,
           "message" => %{"id" => line_message_id, "text" => text}
         },
         source_id: source_id
       }) do
    thread = Conversation.thread_for(source_id)

    {:ok, _} =
      Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    if is_nil(thread.locale) do
      picker = Line.Client.language_picker_message()
      Conversation.deliver(reply_token, source_id, [picker], nil)
    else
      Conversation.handle_message(thread, reply_token, source_id)
    end
  end

  defp handle_user_message(_event), do: :ok

  defp handle_simple_reply(%{
         payload: %{"replyToken" => reply_token, "message" => %{"text" => text}},
         source_id: source_id
       }) do
    messages = [Line.Client.text_message("收到你的訊息：#{text}")]
    Conversation.deliver(reply_token, source_id, messages, nil)
  end

  defp handle_simple_reply(_event), do: :ok

  # Nothing on this path sends to LINE, and `Line.Client` refuses group
  # targets anyway (spec 2026-10-05 §4): the Group chat never hears from the bot.
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

  # The Group chat's three tasks, the snapshot their ids come from, and its
  # full history; never summaries (ADR 0003).
  defp run_group_agent(thread) do
    system = Prompts.group() <> "\n\n" <> Prompts.snapshot_section(Snapshot.build(Clock.today()))
    Agent.run(thread, Tasks.for_chat(:group), system, Assistant.list_messages(thread))
  end

  defp handle_unsend(%{payload: %{"unsend" => %{"messageId" => line_message_id}}}) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: nil) |> Repo.update!()
        discard_pending_drafts_for(message)
        message.thread_id |> Assistant.get_thread!() |> forget_digests(message)
    end
  end

  defp handle_message_edited(
         %{payload: %{"message" => %{"id" => line_message_id, "text" => new_text}}} = event
       ) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: new_text) |> Repo.update!()
        discard_pending_drafts_for(message)

        thread = Assistant.get_thread!(message.thread_id)
        forget_digests(thread, message)

        # The stored sender_id is nil on older or purged rows; the edit
        # event's own sender is checked first.
        sender_id = get_in(event.payload, ["source", "userId"]) || message.sender_id
        rerun_after_edit(thread, sender_id)
    end
  end

  defp rerun_after_edit(%{source_type: "group", source_id: group_id} = thread, sender_id) do
    if Line.blocked?("group", group_id) or Line.blocked?("sender", sender_id) do
      :ok
    else
      thread |> run_group_agent() |> log_failure(thread, "messageEdited")
      maybe_schedule_group_notifier(thread)
    end
  end

  defp rerun_after_edit(thread, _sender_id) do
    thread |> Conversation.run_turn() |> log_failure(thread, "messageEdited")
  end

  # From the stored Drafts, not the Turn: a turn that fails after creating a
  # Draft returns an error, yet its Draft still waits for the teacher.
  defp maybe_schedule_group_notifier(thread) do
    unnotified? =
      Repo.exists?(
        from d in Assistant.Draft,
          where: d.thread_id == ^thread.id and d.state == "pending" and is_nil(d.notified_at)
      )

    if unnotified? do
      {:ok, _} = GroupDraftNotifier.schedule(thread.source_id)
    end

    :ok
  end

  defp log_failure({:ok, _turn}, _thread, _what), do: :ok

  defp log_failure({:error, reason}, thread, what) do
    Logger.error(
      "Ganesha.Assistant.Agent.run/4 failed after #{what} for thread #{thread.id}: #{inspect(reason)}"
    )

    :ok
  end

  defp discard_pending_drafts_for(%Assistant.Message{id: id}) do
    from(d in Assistant.Draft, where: d.origin_message_id == ^id and d.state == "pending")
    |> Repo.all()
    |> Enum.each(&Assistant.discard_draft/1)
  end

  # Spec §6.4: an unsent or edited Teacher chat message invalidates the
  # digests covering its day; the next nightly run writes them again. Group
  # chat and Student chats have no digests (ADR 0003).
  defp forget_digests(%Assistant.Thread{source_type: "teacher"} = thread, message) do
    Memory.invalidate_digests(thread.id, Clock.to_taipei_date(message.inserted_at))
  end

  defp forget_digests(_thread, _message), do: :ok

  defp simple_reply? do
    Application.get_env(:ganesha, :line, [])
    |> Keyword.get(:simple_reply, false)
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
