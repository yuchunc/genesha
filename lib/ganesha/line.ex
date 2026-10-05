defmodule Ganesha.Line do
  @moduledoc """
  Raw LINE webhook events: idempotent persistence and dispatch to
  `Ganesha.Assistant.ProcessEventWorker`. See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md §2, §3.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Ganesha.Line.{BlockedAccount, LineEvent}
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
      payload: without_group_reply_token(event)
    }

    case %LineEvent{} |> LineEvent.changeset(attrs) |> Repo.insert() do
      {:ok, line_event} ->
        if event["mode"] == "active" do
          enqueue(line_event)
        end

        :ok

      {:error, changeset} ->
        if unique_violation?(changeset, :webhook_event_id), do: :ok, else: {:error, changeset}
    end
  end

  def record_event(_event), do: :ok

  @doc "The LINE user ids that get the Teacher chat (config `:line, :teacher_line_user_ids`)."
  @spec teacher_ids() :: [String.t()]
  def teacher_ids do
    Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_ids)
  end

  @spec teacher?(String.t() | nil) :: boolean()
  def teacher?(user_id), do: is_binary(user_id) and user_id in teacher_ids()

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

  # Spec 2026-10-05 §4: a group or room event is stored without its reply
  # token, so no code path can ever answer into a group.
  defp without_group_reply_token(%{"source" => %{"type" => type}} = event)
       when type in ["group", "room"],
       do: Map.delete(event, "replyToken")

  defp without_group_reply_token(event), do: event

  defp unique_violation?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, [constraint: :unique, constraint_name: _]}} -> true
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

  @doc "Whether a group (`\"group\"`) or a sender in every group (`\"sender\"`) is blocked."
  @spec blocked?(String.t(), String.t() | nil) :: boolean()
  def blocked?(_kind, nil), do: false

  def blocked?(kind, line_id) do
    Repo.exists?(from b in BlockedAccount, where: b.kind == ^kind and b.line_id == ^line_id)
  end

  def get_blocked_account(kind, line_id),
    do: Repo.get_by(BlockedAccount, kind: kind, line_id: line_id)

  @doc "Every blocked group and sender, newest first."
  def list_blocked_accounts do
    Repo.all(from b in BlockedAccount, order_by: [desc: b.inserted_at, desc: b.id])
  end

  @doc "Applied by a confirmed `block_account` Draft only (ADR 0001)."
  def block_account(attrs) do
    case %BlockedAccount{} |> BlockedAccount.changeset(attrs) |> Repo.insert() do
      {:ok, blocked} ->
        {:ok, blocked}

      {:error, changeset} ->
        if unique_violation?(changeset, :kind),
          do: {:error, :already_blocked},
          else: {:error, changeset}
    end
  end

  @doc "Applied by a confirmed `unblock_account` Draft only (ADR 0001)."
  def unblock_account(kind, line_id) do
    case Repo.delete_all(
           from b in BlockedAccount, where: b.kind == ^kind and b.line_id == ^line_id
         ) do
      {0, _} -> {:error, :not_blocked}
      {_, _} -> :ok
    end
  end

  def get_event!(id), do: Repo.get!(LineEvent, id)

  def mark_processed(%LineEvent{} = event) do
    event
    |> Ecto.Changeset.change(processed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end
end
