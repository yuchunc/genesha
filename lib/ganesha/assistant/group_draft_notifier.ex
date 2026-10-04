defmodule Ganesha.Assistant.GroupDraftNotifier do
  @moduledoc """
  Pushes pending Group chat Drafts to every teacher's Teacher chat (spec §6.6, §7).

  Inserted with `schedule_in: 180` and `unique: [period: 180, keys: [:group_id]]`
  when a group turn creates Drafts. Each run pushes every still-pending,
  still-unnotified Draft from that group as one text message plus one Draft
  carousel (≤ 12 bubbles), in each teacher's own language; the rest wait for
  the next job. The Drafts count as notified once any teacher's push
  succeeds; when every push fails, `notified_at` stays nil so Oban retries
  (max 3).
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 180, keys: [:group_id], states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Ganesha.{Assistant, Repo}
  alias Ganesha.Assistant.{Draft, Thread}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_bubbles 12

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"group_id" => group_id}}) do
    drafts = list_unnotified_group_drafts(group_id)

    if drafts == [] do
      :ok
    else
      push_and_mark(drafts, group_id)
    end
  end

  @doc """
  Enqueues a notifier run in three minutes. Repeated group Drafts inside the
  unique window collapse to one job (spec §6.6).
  """
  @spec schedule(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(group_id) when is_binary(group_id) do
    %{group_id: group_id}
    |> new(schedule_in: 180, unique: [period: 180, keys: [:group_id]])
    |> Oban.insert()
  end

  defp list_unnotified_group_drafts(group_id) do
    Repo.all(
      from d in Draft,
        join: t in Thread,
        on: d.thread_id == t.id,
        where: t.source_type == "group" and t.source_id == ^group_id,
        where: d.state == "pending" and is_nil(d.notified_at),
        order_by: [asc: d.inserted_at, asc: d.id],
        preload: [:student]
    )
  end

  defp push_and_mark(drafts, group_id) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)

    results =
      Enum.map(Ganesha.Line.teacher_ids(), fn teacher_id ->
        line_client().push(
          teacher_id,
          messages(shown, length(hidden), teacher_locale(teacher_id))
        )
      end)

    if :ok in results do
      with :ok <- Assistant.mark_drafts_notified(Enum.map(shown, & &1.id)) do
        schedule_remainder(hidden, group_id)
      end
    else
      Enum.find(results, {:error, :no_teachers}, &match?({:error, _}, &1))
    end
  end

  defp messages(shown, hidden_count, locale) do
    text =
      if hidden_count > 0 do
        Labels.t(:group_drafts_push_intro, locale) <>
          "\n\n" <>
          Labels.t(:more_drafts, locale, count: hidden_count)
      else
        Labels.t(:group_drafts_push_intro, locale)
      end

    alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))

    [
      Client.text_message(text),
      Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))
    ]
  end

  # The rest go in the next job (spec §6.6). This job is still executing, so
  # schedule/1 would collapse into it; the follow-up skips the unique check.
  defp schedule_remainder([], _group_id), do: :ok

  defp schedule_remainder(_hidden, group_id) do
    {:ok, _} = %{group_id: group_id} |> new(schedule_in: 60, unique: false) |> Oban.insert()
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
