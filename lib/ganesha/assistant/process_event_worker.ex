defmodule Ganesha.Assistant.ProcessEventWorker do
  @moduledoc """
  Runs one `line_events` row through the shared agent loop (spec §2). The
  teacher's 1:1 messages get a LINE reply (falling back to push) carrying
  the agent's answer and, when a draft was created, a confirm/discard quick
  reply. Every other event is currently a no-op — group messages are wired
  in by Task 17, postbacks by Task 16.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Agent
  alias Ganesha.Line

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"line_event_id" => line_event_id}}) do
    line_event = Line.get_event!(line_event_id)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    result = route(line_event, teacher_id)
    Line.mark_processed(line_event)
    result
  end

  defp route(%{source_type: "user", source_id: sender_id, raw_type: "message"} = event, teacher_id)
       when sender_id == teacher_id do
    handle_teacher_message(event)
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
        send_reply(reply_token, source_id, reply_text, List.first(draft_ids))
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_teacher_message(_event), do: :ok

  defp send_reply(reply_token, source_id, text, draft_id) do
    message = Ganesha.Line.Client.text_message(text, draft_id)

    case line_client().reply(reply_token, [message]) do
      :ok -> :ok
      {:error, _reason} -> line_client().push(source_id, [message])
    end
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
