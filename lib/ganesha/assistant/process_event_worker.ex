defmodule Ganesha.Assistant.ProcessEventWorker do
  @moduledoc """
  Runs one `line_events` row through the shared agent loop (spec §2). The
  teacher's 1:1 messages get a LINE reply (falling back to push) carrying
  the agent's answer and, for every draft created this turn, its own
  confirm/discard quick reply. A failed agent run is reported back to the
  teacher rather than retried - a retry would re-run `handle_teacher_message/1`
  with the same args, which has already appended her message (and any
  partial assistant/tool/draft rows the failed turn wrote), re-ingesting it
  and risking duplicate pending drafts for one real fact. Every other event
  is currently a no-op — group messages are wired in by Task 17, postbacks
  by Task 16.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  require Logger

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Agent
  alias Ganesha.Line
  alias Ganesha.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"line_event_id" => line_event_id}}) do
    line_event = Line.get_event!(line_event_id)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    :ok = route(line_event, teacher_id)
    Line.mark_processed(line_event)
    :ok
  end

  defp route(%{source_type: "user", raw_type: "message"} = event, teacher_id) do
    if simple_reply?(),
      do: handle_simple_reply(event),
      else: handle_user_message(event, teacher_id)
  end

  defp route(%{source_type: "user", raw_type: "postback"} = event, teacher_id) do
    handle_user_postback(event, teacher_id)
  end

  defp route(
         %{source_type: "group", source_id: group_id, raw_type: "message"} = event,
         teacher_id
       ) do
    sender_id = get_in(event.payload, ["source", "userId"])

    if sender_id == teacher_id do
      :ok
    else
      handle_group_message(event, group_id)
    end
  end

  defp route(%{raw_type: "unsend"} = event, _teacher_id), do: handle_unsend(event)
  defp route(%{raw_type: "messageEdited"} = event, _teacher_id), do: handle_message_edited(event)
  defp route(_event, _teacher_id), do: :ok

  defp handle_user_message(
         %{
           payload: %{
             "replyToken" => reply_token,
             "message" => %{"id" => line_message_id, "text" => text}
           },
           source_id: source_id
         },
         teacher_id
       ) do
    {source_type, thread} = user_thread(source_id, teacher_id)

    {:ok, _} =
      Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    if is_nil(thread.locale) do
      line_client().reply(reply_token, [line_client().language_picker_message()])
      :ok
    else
      run_agent_and_reply(thread, source_type, reply_token, source_id, thread.locale)
    end
  end

  defp handle_user_message(_event, _teacher_id), do: :ok

  defp handle_simple_reply(%{
         payload: %{"replyToken" => reply_token, "message" => %{"text" => text}},
         source_id: source_id
       }) do
    send_reply(reply_token, source_id, "收到你的訊息：#{text}", [])
    :ok
  end

  defp handle_simple_reply(_event), do: :ok

  defp simple_reply?() do
    Application.get_env(:ganesha, :line, [])
    |> Keyword.get(:simple_reply, false)
  end

  # No `line_client()` call anywhere in this function or anything it calls —
  # that absence, not a runtime check, is what guarantees the group never
  # receives a message from the bot (spec §4.3, §8 guardrail #2).
  defp handle_group_message(
         %{payload: %{"message" => %{"id" => line_message_id, "text" => text}}},
         group_id
       ) do
    {:ok, thread} = Assistant.get_or_create_thread("group", group_id)

    {:ok, _} =
      Assistant.append_message(thread, "user", text, nil, line_message_id: line_message_id)

    case Agent.run(thread, Assistant.tools(), Assistant.group_system_prompt()) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Ganesha.Assistant.Agent.run/3 failed for group thread #{thread.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp handle_group_message(_event, _group_id), do: :ok

  defp handle_unsend(%{payload: %{"unsend" => %{"messageId" => line_message_id}}}) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: nil) |> Repo.update!()
        discard_pending_drafts_for(message)
        :ok
    end
  end

  defp handle_message_edited(%{
         payload: %{"message" => %{"id" => line_message_id, "text" => new_text}}
       }) do
    case Repo.get_by(Assistant.Message, line_message_id: line_message_id) do
      nil ->
        :ok

      message ->
        message |> Ecto.Changeset.change(content: new_text) |> Repo.update!()
        discard_pending_drafts_for(message)

        thread = Repo.get!(Assistant.Thread, message.thread_id)

        system_prompt =
          case thread.source_type do
            "teacher" -> Assistant.teacher_system_prompt(thread.locale || "zh-TW")
            "group" -> Assistant.group_system_prompt()
            _ -> Assistant.user_system_prompt(thread.locale || "zh-TW")
          end

        tools =
          if thread.source_type in ["teacher", "group"], do: Assistant.tools(), else: []

        case Agent.run(thread, tools, system_prompt) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "Ganesha.Assistant.Agent.run/3 failed after messageEdited for thread #{thread.id}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defp discard_pending_drafts_for(%Assistant.Message{id: id}) do
    from(d in Assistant.Draft, where: d.origin_message_id == ^id and d.state == "pending")
    |> Repo.all()
    |> Enum.each(&Assistant.discard_draft/1)
  end

  defp handle_user_postback(
         %{
           payload: %{"replyToken" => reply_token, "postback" => %{"data" => data}},
           source_id: source_id
         },
         teacher_id
       ) do
    params = URI.decode_query(data)

    case params["action"] do
      "set_locale" ->
        handle_set_locale_postback(reply_token, source_id, params["locale"], teacher_id)

      "confirm" ->
        handle_draft_postback(reply_token, params, source_id, teacher_id)

      "discard" ->
        handle_draft_postback(reply_token, params, source_id, teacher_id)

      _ ->
        line_client().reply(reply_token, [line_client().text_message("無法辨識的操作。")])
        :ok
    end
  end

  defp handle_set_locale_postback(reply_token, source_id, locale, teacher_id) do
    {source_type, thread} = user_thread(source_id, teacher_id)

    case Assistant.set_locale(thread, locale) do
      {:ok, thread} ->
        if pending_user_turn?(thread) do
          run_agent_and_reply(thread, source_type, reply_token, source_id, locale)
        else
          send_reply(reply_token, source_id, locale_welcome(locale), [])
          :ok
        end

      {:error, _} ->
        line_client().reply(reply_token, [line_client().language_picker_message()])
        :ok
    end
  end

  defp handle_draft_postback(reply_token, params, source_id, teacher_id) do
    if source_id != teacher_id do
      line_client().reply(reply_token, [line_client().text_message("無法辨識的操作。")])
      :ok
    else
      draft = Assistant.get_draft!(String.to_integer(params["draft_id"]))
      reply_text = resolve_postback(params["action"], draft)
      line_client().reply(reply_token, [line_client().text_message(reply_text)])
      :ok
    end
  end

  defp user_thread(source_id, teacher_id) do
    source_type = if source_id == teacher_id, do: "teacher", else: "user"
    {:ok, thread} = Assistant.get_or_create_thread(source_type, source_id)
    {source_type, thread}
  end

  defp pending_user_turn?(thread) do
    case List.last(Assistant.list_messages(thread)) do
      %{role: "user"} -> true
      _ -> false
    end
  end

  defp run_agent_and_reply(thread, source_type, reply_token, source_id, locale) do
    {prompt, tools} =
      case source_type do
        "teacher" -> {Assistant.teacher_system_prompt(locale), Assistant.tools()}
        _ -> {Assistant.user_system_prompt(locale), []}
      end

    case Agent.run(thread, tools, prompt) do
      {:ok, %{text: reply_text, draft_ids: draft_ids}} ->
        send_reply(reply_token, source_id, reply_text, draft_ids)
        :ok

      {:error, reason} ->
        Logger.error(
          "Ganesha.Assistant.Agent.run/3 failed for thread #{thread.id}: #{inspect(reason)}"
        )

        apology =
          if locale == "en",
            do: "Sorry, I couldn't process that message. Please try again later.",
            else: "抱歉，我現在無法處理這則訊息，請稍後再試一次。"

        send_reply(reply_token, source_id, apology, [])
        :ok
    end
  end

  defp locale_welcome("en"), do: "Thanks! How can I help you today?"
  defp locale_welcome(_), do: "好的！有什麼需要我幫忙的？"

  defp resolve_postback("confirm", draft) do
    case Assistant.confirm_draft(draft, "line:teacher") do
      {:ok, _} -> "已確認並記錄。"
      {:error, :not_pending} -> "這筆草稿已經處理過了。"
      {:error, {:failed, failed}} -> "無法套用：#{failed.failure_reason}"
    end
  end

  defp resolve_postback("discard", draft) do
    case Assistant.discard_draft(draft) do
      {:ok, _} -> "已捨棄。"
      {:error, :not_pending} -> "這筆草稿已經處理過了。"
    end
  end

  defp resolve_postback(_unknown, _draft), do: "無法辨識的操作。"

  defp send_reply(reply_token, source_id, text, draft_ids) do
    messages = build_messages(text, draft_ids)

    case line_client().reply(reply_token, messages) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("line reply failed (#{inspect(reason)}), falling back to push")

        case line_client().push(source_id, messages) do
          :ok -> :ok
          {:error, push_reason} -> Logger.error("line push also failed: #{inspect(push_reason)}")
        end

        :ok
    end
  end

  # The first draft's confirm/discard rides on the actual answer; any further
  # draft from the same turn (e.g. a payment plus an attendance mark in one
  # message) gets its own short follow-up message with its own quick reply -
  # there is no other surface a draft can be confirmed from, so leaving it
  # off any message would make that draft permanently unconfirmable.
  defp build_messages(text, []), do: [line_client().text_message(text)]

  defp build_messages(text, [first_draft_id | rest]) do
    [
      line_client().text_message(text, first_draft_id)
      | Enum.map(rest, &line_client().text_message("另一筆草稿待確認", &1))
    ]
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
