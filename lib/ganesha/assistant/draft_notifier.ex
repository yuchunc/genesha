defmodule Ganesha.Assistant.DraftNotifier do
  @moduledoc """
  Pushes a thread's pending Drafts that no teacher has been sent yet to every
  teacher's Teacher chat (spec 2026-10-02 §6.6, §7; spec 2026-10-06 §3). The
  Group chat and Student chats propose Drafts their own chat never shows as
  cards.

  A Group chat's run is 3 minutes after its first Draft, and later Drafts
  join it. A Student chat's run is 5 minutes after its latest unnotified
  Draft: a new Draft moves the waiting job, a turn without one does not. Each
  run pushes one intro text plus one Draft carousel (≤ 12 bubbles) in each
  teacher's own language; the rest wait for the next job. The Drafts count as
  notified once any teacher's push succeeds; when every push fails,
  `notified_at` stays nil so Oban retries (max 3).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Ganesha.{Assistant, Repo}
  alias Ganesha.Assistant.{Draft, Thread}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_bubbles 12
  @group_delay 180
  @student_delay 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"thread_id" => thread_id}}) do
    thread = Assistant.get_thread!(thread_id)

    case list_unnotified(thread) do
      [] -> :ok
      drafts -> push_and_mark(drafts, thread)
    end
  end

  @doc """
  Schedules a run when the thread has a pending Draft no teacher has been sent.
  Reads the stored Drafts, not a Turn: a turn that fails after creating a
  Draft still leaves it waiting.
  """
  @spec schedule_if_pending(Thread.t()) :: :ok
  def schedule_if_pending(%Thread{} = thread) do
    if Repo.exists?(unnotified(thread)) do
      {:ok, _} = schedule(thread)
    end

    :ok
  end

  @doc """
  Enqueues a run with the thread's chat timing (see the moduledoc). A Student
  chat with no unnotified pending Draft gets `{:error, :no_pending_draft}`.
  """
  @spec schedule(Thread.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(%Thread{source_type: "group", id: id}) do
    %{thread_id: id}
    |> new(schedule_in: @group_delay, unique: [period: @group_delay, keys: [:thread_id]])
    |> Oban.insert()
  end

  def schedule(%Thread{source_type: "user", id: id} = thread) do
    case latest_unnotified_at(thread) do
      nil ->
        {:error, :no_pending_draft}

      inserted_at ->
        %{thread_id: id}
        |> new(
          scheduled_at: DateTime.add(inserted_at, @student_delay),
          unique: [period: :infinity, keys: [:thread_id], states: [:available, :scheduled]],
          replace: [scheduled: [:scheduled_at]]
        )
        |> Oban.insert()
    end
  end

  defp latest_unnotified_at(thread) do
    Repo.one(from d in unnotified(thread), select: max(d.inserted_at))
  end

  defp unnotified(thread) do
    from d in Draft,
      where: d.thread_id == ^thread.id and d.state == "pending" and is_nil(d.notified_at)
  end

  defp list_unnotified(thread) do
    Repo.all(
      from d in unnotified(thread),
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:student]
    )
  end

  defp push_and_mark(drafts, thread) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)

    results =
      Enum.map(Ganesha.Line.teacher_ids(), fn teacher_id ->
        line_client().push(
          teacher_id,
          messages(thread, shown, length(hidden), teacher_locale(teacher_id))
        )
      end)

    if :ok in results do
      with :ok <- Assistant.mark_drafts_notified(Enum.map(shown, & &1.id)) do
        schedule_remainder(hidden, thread)
      end
    else
      Enum.find(results, {:error, :no_teachers}, &match?({:error, _}, &1))
    end
  end

  defp messages(thread, shown, hidden_count, locale) do
    intro = Labels.t(intro_key(thread), locale)

    text =
      if hidden_count > 0,
        do: intro <> "\n\n" <> Labels.t(:more_drafts, locale, count: hidden_count),
        else: intro

    alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))

    [
      Client.text_message(text),
      Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))
    ]
  end

  defp intro_key(%Thread{source_type: "group"}), do: :group_drafts_push_intro
  defp intro_key(%Thread{source_type: "user"}), do: :student_drafts_push_intro

  # The rest go in the next job (spec §6.6). This job is still executing, so a
  # unique insert could collapse into it; the follow-up skips the unique check.
  defp schedule_remainder([], _thread), do: :ok

  defp schedule_remainder(_hidden, thread) do
    {:ok, _} = %{thread_id: thread.id} |> new(schedule_in: 60, unique: false) |> Oban.insert()
    :ok
  end

  defp teacher_locale(teacher_id) do
    Repo.one(
      from t in Thread,
        where: t.source_type == "teacher" and t.source_id == ^teacher_id,
        select: t.locale
    ) || "zh-TW"
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
