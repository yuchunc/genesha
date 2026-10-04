defmodule Ganesha.Assistant.GroupDraftNotifier do
  @moduledoc """
  Pushes pending Group chat Drafts to the Teacher chat (spec §6.6, §7).

  Inserted with `schedule_in: 180` and `unique: [period: 180, keys: [:group_id]]`
  when a group turn creates Drafts. Each run pushes every still-pending,
  still-unnotified Draft from that group as one text message plus one Draft
  carousel (≤ 12 bubbles); the rest wait for the next job. A push failure
  leaves `notified_at` nil so Oban retries (max 3).
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
      push_and_mark(drafts)
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

  defp push_and_mark(drafts) do
    locale = teacher_locale()
    {shown, hidden} = Enum.split(drafts, @max_bubbles)
    hidden_count = length(hidden)

    text =
      if hidden_count > 0 do
        Labels.t(:group_drafts_push_intro, locale) <>
          "\n\n" <>
          Labels.t(:more_drafts, locale, count: hidden_count)
      else
        Labels.t(:group_drafts_push_intro, locale)
      end

    alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))

    messages = [
      Client.text_message(text),
      Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))
    ]

    teacher_id = teacher_line_user_id()

    with :ok <- line_client().push(teacher_id, messages),
         :ok <- Assistant.mark_drafts_notified(Enum.map(shown, & &1.id)) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp teacher_locale do
    teacher_id = teacher_line_user_id()

    case Repo.one(
           from t in Thread,
             where: t.source_type == "teacher" and t.source_id == ^teacher_id,
             select: t.locale
         ) do
      nil -> "zh-TW"
      locale -> locale || "zh-TW"
    end
  end

  defp teacher_line_user_id do
    Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
