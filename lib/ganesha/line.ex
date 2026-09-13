defmodule Ganesha.Line do
  @moduledoc """
  Raw LINE webhook events: idempotent persistence and dispatch to
  `Ganesha.Assistant.ProcessEventWorker`. See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md §2, §3.
  """

  require Logger

  alias Ganesha.Line.LineEvent
  alias Ganesha.Repo

  @doc """
  Persists one webhook event, deduping on `webhookEventId`. Enqueues async
  processing only for a newly-inserted, active-mode event — a duplicate
  delivery or a standby-mode event is stored but never processed twice.
  """
  def record_event(%{"webhookEventId" => webhook_event_id} = event) do
    attrs = %{
      webhook_event_id: webhook_event_id,
      source_type: get_in(event, ["source", "type"]),
      source_id: source_id(event),
      raw_type: event["type"],
      payload: event
    }

    case %LineEvent{} |> LineEvent.changeset(attrs) |> Repo.insert() do
      {:ok, line_event} ->
        if event["mode"] == "active" do
          enqueue(line_event)
        end

        :ok

      {:error, changeset} ->
        if unique_violation?(changeset), do: :ok, else: {:error, changeset}
    end
  end

  def record_event(_event), do: :ok

  # The thing later code routes on: which *group* a group message belongs
  # to, or which *user* sent a 1:1 message — never the per-message sender
  # inside a group, which real LINE group payloads also carry as `userId`
  # alongside `groupId`. Picking `userId` unconditionally here would make
  # every group message's `source_id` the sender, not the group, and break
  # `Ganesha.Assistant.ProcessEventWorker`'s group-thread routing.
  defp source_id(%{"source" => %{"type" => "group", "groupId" => group_id}}), do: group_id
  defp source_id(%{"source" => %{"type" => "room", "roomId" => room_id}}), do: room_id
  defp source_id(%{"source" => %{"type" => "user", "userId" => user_id}}), do: user_id
  defp source_id(_event), do: nil

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn
      {:webhook_event_id, {_, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end

  defp enqueue(%LineEvent{id: id}) do
    case %{"line_event_id" => id}
         |> Ganesha.Assistant.ProcessEventWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("failed to enqueue line_event #{id}: #{inspect(reason)}")
    end
  end

  def get_event!(id), do: Repo.get!(LineEvent, id)

  def mark_processed(%LineEvent{} = event) do
    event
    |> Ecto.Changeset.change(processed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end
end
