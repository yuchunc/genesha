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

  defp studio_vocabulary("en") do
    """
    Reply in English. Be professional and concise. Use yoga-studio terms (class credits,
    makeup class, drop-in, trial, monthly package). You can look up students, schedules,
    and payments, and create drafts (payment, attendance, makeup) for the teacher to
    confirm — never apply a draft yourself; only she can confirm.
    """
  end

  defp studio_vocabulary(_locale) do
    """
    只用繁體中文回覆，語氣專業、簡潔，使用瑜珈教室慣用詞彙（堂數、補課、單堂、體驗、
    月課程）。你可以查詢學生、堂數與帳務資料，也可以建立「草稿」（付款、出席、補課
    需求）供她確認 — 你永遠不能把草稿直接變成正式紀錄，只有她本人確認後才算數。
    """
  end

  def teacher_system_prompt(locale \\ "zh-TW") do
    role =
      if locale == "en",
        do: "You are the studio ledger assistant speaking with the teacher directly.",
        else: "你是師父的課程記帳助理，正在跟她本人對話。"

    role <> studio_vocabulary(locale)
  end

  # Non-teacher 1:1 chats run with no tools, so the model has no studio data at
  # all; without this rule it invents class times and prices.
  def user_system_prompt("en") do
    """
    You are a helpful assistant for this yoga studio's LINE account. Reply in English. \
    Be brief and friendly. You have no access to the studio's schedule, prices, \
    class availability, bookings, or anyone's class credits. Never state or guess \
    times, dates, prices, or availability. When asked about any of these, say the \
    teacher will reply personally.
    """
  end

  def user_system_prompt(_locale) do
    """
    你是這間瑜珈教室 LINE 官方帳號的助理。只用繁體中文回覆，語氣簡短友善。\
    你看不到教室的課表、價格、名額、預約或任何人的堂數。絕對不要說出或猜測\
    上課時間、日期、價格或名額；被問到這些時，告訴對方老師會親自回覆。
    """
  end

  def group_system_prompt do
    "你正在被動觀察師父的學生群組對話，任何人都看不到你的回覆 — 你唯一能做的事是視
    情況建立草稿供師父之後確認，絕不能、也沒有管道對群組發送任何訊息。" <>
      studio_vocabulary("zh-TW")
  end

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
