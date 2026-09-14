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

  require Logger

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Agent
  alias Ganesha.Line

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"line_event_id" => line_event_id}}) do
    line_event = Line.get_event!(line_event_id)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    :ok = route(line_event, teacher_id)
    Line.mark_processed(line_event)
    :ok
  end

  defp route(%{source_type: "user", source_id: sender_id, raw_type: "message"} = event, teacher_id)
       when sender_id == teacher_id do
    handle_teacher_message(event)
  end

  defp route(%{source_type: "user", source_id: sender_id, raw_type: "postback"} = event, teacher_id)
       when sender_id == teacher_id do
    handle_postback(event)
  end

  defp route(%{source_type: "group", source_id: group_id, raw_type: "message"} = event, teacher_id) do
    sender_id = get_in(event.payload, ["source", "userId"])

    if sender_id == teacher_id do
      :ok
    else
      handle_group_message(event, group_id)
    end
  end

  defp route(_event, _teacher_id), do: :ok

  defp handle_teacher_message(%{
         payload: %{"replyToken" => reply_token, "message" => %{"text" => text}},
         source_id: source_id
       }) do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", source_id)
    {:ok, _} = Assistant.append_message(thread, "user", text, nil)

    case Agent.run(thread, Assistant.tools(), Assistant.teacher_system_prompt()) do
      {:ok, %{text: reply_text, draft_ids: draft_ids}} ->
        send_reply(reply_token, source_id, reply_text, draft_ids)
        :ok

      {:error, reason} ->
        Logger.error("Ganesha.Assistant.Agent.run/3 failed for thread #{thread.id}: #{inspect(reason)}")
        send_reply(reply_token, source_id, "抱歉，我現在無法處理這則訊息，請稍後再試一次。", [])
        :ok
    end
  end

  defp handle_teacher_message(_event), do: :ok

  # No `line_client()` call anywhere in this function or anything it calls —
  # that absence, not a runtime check, is what guarantees the group never
  # receives a message from the bot (spec §4.3, §8 guardrail #2).
  defp handle_group_message(%{payload: %{"message" => %{"text" => text}}}, group_id) do
    {:ok, thread} = Assistant.get_or_create_thread("group", group_id)
    {:ok, _} = Assistant.append_message(thread, "user", text, nil)

    case Agent.run(thread, Assistant.tools(), Assistant.group_system_prompt()) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_group_message(_event, _group_id), do: :ok

  defp handle_postback(%{payload: %{"replyToken" => reply_token, "postback" => %{"data" => data}}}) do
    params = URI.decode_query(data)
    draft = Assistant.get_draft!(String.to_integer(params["draft_id"]))
    reply_text = resolve_postback(params["action"], draft)

    line_client().reply(reply_token, [line_client().text_message(reply_text)])
    :ok
  end

  defp resolve_postback("confirm", draft) do
    case Assistant.apply_draft(draft, "line:teacher") do
      {:ok, _} -> "已確認並記錄。"
      {:error, :missing_purchase_id} -> "這筆草稿缺少對應的購買記錄，請於 App 內編輯後確認。"
      {:error, :not_pending} -> "這筆草稿已經處理過了。"
      {:error, _changeset} -> "記錄失敗，請於 App 內手動處理。"
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
