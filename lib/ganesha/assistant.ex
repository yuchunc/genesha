defmodule Ganesha.Assistant do
  @moduledoc """
  Threads, messages and Drafts for the LINE assistant. See
  docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Assistant.{Draft, Message, Tasks, Thread}
  alias Ganesha.Repo

  def get_or_create_thread(source_type, source_id) do
    case Repo.get_by(Thread, source_type: source_type, source_id: source_id) do
      %Thread{} = thread ->
        {:ok, thread}

      nil ->
        %Thread{}
        |> Thread.changeset(%{source_type: source_type, source_id: source_id})
        |> Repo.insert()
    end
  end

  def get_thread!(id), do: Repo.get!(Thread, id)

  def list_threads(source_type) do
    Repo.all(from t in Thread, where: t.source_type == ^source_type, order_by: t.id)
  end

  @supported_locales ~w(zh-TW en)

  def set_locale(%Thread{} = thread, locale) when locale in @supported_locales do
    thread
    |> Thread.changeset(%{locale: locale})
    |> Repo.update()
  end

  def set_locale(_thread, _locale), do: {:error, :invalid_locale}

  def list_messages(%Thread{} = thread) do
    Repo.all(from m in Message, where: m.thread_id == ^thread.id, order_by: m.id)
  end

  def append_message(%Thread{} = thread, role, content, tool_calls, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      thread_id: thread.id,
      role: role,
      content: content,
      tool_calls: tool_calls,
      line_message_id: opts[:line_message_id]
    })
    |> Repo.insert()
  end

  @doc """
  Appends `text` as a new line of message `id` (spec §6.1 step 7): the cards
  a turn sent are recorded on that turn's own reply, so the model later sees
  them. Addressed by id because other assistant messages (Confirm outcomes)
  can land in the thread while a turn is being delivered.
  """
  def append_to_message(id, text) when is_integer(id) and is_binary(text) do
    case Repo.get(Message, id) do
      nil ->
        {:error, :not_found}

      message ->
        content = Enum.join(Enum.reject([message.content, text], &(&1 in [nil, ""])), "\n")
        message |> Ecto.Changeset.change(content: content) |> Repo.update()
    end
  end

  @doc """
  Inserts a pending Draft stamped with the thread's latest user message. With
  `replaces: id`, the same transaction sets that Draft to `replaced` — only if
  it belongs to this thread and is still pending (spec §2 rule 3).
  """
  def create_draft(%Thread{} = thread, attrs, opts \\ []) do
    origin = latest_user_message(thread)

    attrs =
      attrs
      |> Map.put(:thread_id, thread.id)
      |> Map.put(:origin_message_id, origin && origin.id)

    Repo.transaction(fn ->
      case %Draft{} |> Draft.changeset(attrs) |> Repo.insert() do
        {:ok, draft} ->
          replace(thread, opts[:replaces], draft)
          draft

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp replace(%Thread{id: thread_id}, old_id, %Draft{id: new_id}) when is_integer(old_id) do
    from(d in Draft,
      where: d.id == ^old_id and d.thread_id == ^thread_id and d.state == "pending"
    )
    |> Repo.update_all(set: [state: "replaced", replaced_by_id: new_id, updated_at: now()])
  end

  defp replace(_thread, _old_id, _draft), do: :ok

  defp latest_user_message(%Thread{} = thread) do
    Repo.one(
      from m in Message,
        where: m.thread_id == ^thread.id and m.role == "user",
        order_by: [desc: m.id],
        limit: 1
    )
  end

  def get_draft!(id), do: Repo.get!(Draft, id)

  def get_draft(id) when is_integer(id), do: Repo.get(Draft, id)

  @doc "The Drafts with these ids, in the order given."
  def get_drafts([]), do: []

  def get_drafts(ids) do
    by_id = Repo.all(from d in Draft, where: d.id in ^ids) |> Map.new(&{&1.id, &1})
    ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  @doc """
  Confirms a pending Draft (spec §4.2, §6.3). A compare-and-set claims it
  pending → applied, so concurrent confirms apply it exactly once; the task's
  `apply/2` then runs in the same transaction. A rule violation rolls it all
  back and marks the Draft `failed` with the reason. An exception rolls back,
  leaves the Draft pending, and propagates.
  """
  def confirm_draft(%Draft{} = draft, confirmed_by) do
    case Tasks.fetch(draft.kind) do
      {:ok, task} -> claim_and_apply(draft, task, confirmed_by)
      :error -> mark_failed(draft, :unknown_kind)
    end
  end

  defp claim_and_apply(draft, task, confirmed_by) do
    result =
      Repo.transaction(fn ->
        with {1, _} <- claim_pending(draft.id),
             {:ok, {record_type, record_id}} <- task.apply(draft.parsed, confirmed_by),
             {:ok, applied} <-
               draft |> Draft.apply_changeset(record_type, record_id) |> Repo.update() do
          applied
        else
          {0, _} -> Repo.rollback(:not_pending)
          {:error, reason} -> Repo.rollback({:apply_failed, reason})
        end
      end)

    case result do
      {:ok, applied} -> {:ok, applied}
      {:error, :not_pending} -> {:error, :not_pending}
      {:error, {:apply_failed, reason}} -> mark_failed(draft, reason)
    end
  end

  # Compare-and-set on `state == "pending"`: two concurrent confirms (or a
  # retried job racing a postback tap) can never both get past this point.
  # Runs inside the caller's transaction, so a later failure rolls it back.
  defp claim_pending(id) do
    Repo.update_all(from(d in Draft, where: d.id == ^id and d.state == "pending"),
      set: [state: "applied", updated_at: now()]
    )
  end

  defp mark_failed(%Draft{id: id}, reason) do
    from(d in Draft, where: d.id == ^id and d.state == "pending")
    |> Repo.update_all(
      set: [state: "failed", failure_reason: failure_reason(reason), updated_at: now()]
    )
    |> case do
      {1, _} -> {:error, {:failed, Repo.get!(Draft, id)}}
      {0, _} -> {:error, :not_pending}
    end
  end

  # Spec §7: an atom name, or the changeset's errors joined as `field: message`.
  defp failure_reason(%Ecto.Changeset{} = changeset), do: format_changeset_errors(changeset)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_binary(reason), do: reason
  defp failure_reason(reason), do: inspect(reason)

  @doc "Discards a pending Draft; compare-and-set, so a stale copy cannot undo a confirm."
  def discard_draft(%Draft{id: id}) do
    from(d in Draft, where: d.id == ^id and d.state == "pending")
    |> Repo.update_all(set: [state: "discarded", updated_at: now()])
    |> case do
      {1, _} -> {:ok, Repo.get!(Draft, id)}
      {0, _} -> {:error, :not_pending}
    end
  end

  @doc "Every pending Draft, oldest first, with its student loaded."
  def list_pending_drafts do
    Repo.all(
      from d in Draft,
        where: d.state == "pending",
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:student]
    )
  end

  @doc """
  The Draft's description from its task's `describe/2`. A Draft of a retired
  kind (kept as history) falls back to its kind as the title.
  """
  def describe_draft(%Draft{kind: kind, parsed: parsed}, locale) do
    case Tasks.fetch(kind) do
      {:ok, task} -> task.describe(parsed || %{}, locale)
      :error -> %{title: kind, lines: [], changes: [], web_path: nil}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "A changeset's errors as `field: message`, joined with `; ` (spec §7)."
  def format_changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> Enum.join("; ")
  end
end
