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
  Persists one webhook event, deduping on `webhookEventId`, and for an
  active-mode event enqueues its `Ganesha.Assistant.ProcessEventWorker` job in
  the same transaction, so no row is stored without its job (spec 2026-10-07
  §5). A duplicate delivery is `:ok` and never processed twice; a
  standby-mode event is stored only. Any other failure stores nothing and
  returns `{:error, reason}`, so the webhook answers 500 and LINE redelivers.
  """
  @spec record_event(map()) :: :ok | {:error, term()}
  def record_event(%{"webhookEventId" => webhook_event_id} = event) do
    attrs = %{
      webhook_event_id: webhook_event_id,
      source_type: get_in(event, ["source", "type"]),
      source_id: source_id(event),
      raw_type: event["type"],
      payload: without_group_reply_token(event)
    }

    case Repo.transaction(fn -> insert_and_enqueue(attrs, event["mode"]) end) do
      {:ok, :ok} ->
        :ok

      {:error, reason} ->
        if duplicate?(reason) do
          :ok
        else
          Logger.error("failed to record LINE event #{webhook_event_id}: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  def record_event(_event), do: :ok

  defp insert_and_enqueue(attrs, mode) do
    with {:ok, line_event} <- %LineEvent{} |> LineEvent.changeset(attrs) |> Repo.insert(),
         :ok <- enqueue(line_event, mode) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

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

  defp duplicate?(%Ecto.Changeset{data: %LineEvent{}} = changeset),
    do: unique_violation?(changeset, :webhook_event_id)

  defp duplicate?(_reason), do: false

  defp unique_violation?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end

  defp enqueue(%LineEvent{id: id}, "active") do
    job = Ganesha.Assistant.ProcessEventWorker.new(%{"line_event_id" => id})

    with {:ok, _job} <- Oban.insert(job), do: :ok
  end

  defp enqueue(_line_event, _mode), do: :ok

  @doc """
  Whether the event's chat has an earlier active-mode event still unprocessed
  and younger than ten minutes; its job waits for that one (spec 2026-10-07
  §5). A standby-mode event is never enqueued, so it never holds the chat
  back; neither does an older one that never processed. An event without a
  chat never waits.
  """
  @spec earlier_unprocessed?(%LineEvent{}) :: boolean()
  def earlier_unprocessed?(%LineEvent{source_id: nil}), do: false

  def earlier_unprocessed?(%LineEvent{id: id, source_id: source_id}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-600) |> DateTime.truncate(:second)

    Repo.exists?(
      from e in LineEvent,
        where:
          e.source_id == ^source_id and e.id < ^id and is_nil(e.processed_at) and
            e.inserted_at > ^cutoff and json_extract_path(e.payload, ["mode"]) == "active"
    )
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

  @doc """
  The group's LINE name, or its id when LINE can't say (spec 2026-10-05 §3).
  Read-only.
  """
  @spec group_name(String.t()) :: String.t()
  def group_name(group_id) when is_binary(group_id) do
    case line_client().get_group_summary(group_id) do
      {:ok, %{"groupName" => name}} when is_binary(name) and name != "" ->
        name

      other ->
        Logger.warning("LINE group summary failed for #{group_id}: #{inspect(other)}")
        group_id
    end
  end

  def get_event!(id), do: Repo.get!(LineEvent, id)

  def mark_processed(%LineEvent{} = event) do
    event
    |> Ecto.Changeset.change(processed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
