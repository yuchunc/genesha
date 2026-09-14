defmodule Ganesha.Assistant.PurgeGroupRawTextWorker do
  @moduledoc """
  Hourly sweep enforcing the 24h raw-text retention window for anything
  sourced from the group, or from an unrecognised 1:1 sender — the
  teacher's own thread and `drafts.parsed` are exempt (spec §7).
  """
  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Ganesha.Assistant.{Message, Thread}
  alias Ganesha.Line.LineEvent
  alias Ganesha.Repo

  @retention_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_seconds, :second)
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)

    purge_line_events(cutoff, teacher_id)
    purge_group_messages(cutoff)

    :ok
  end

  defp purge_line_events(cutoff, teacher_id) do
    from(e in LineEvent,
      where: e.inserted_at < ^cutoff,
      where: not (e.source_type == "user" and e.source_id == ^teacher_id)
    )
    |> Repo.update_all(set: [payload: %{"purged" => true}])
  end

  defp purge_group_messages(cutoff) do
    group_thread_ids = from(t in Thread, where: t.source_type == "group", select: t.id)

    from(m in Message,
      where: m.thread_id in subquery(group_thread_ids),
      where: m.inserted_at < ^cutoff,
      where: not is_nil(m.content)
    )
    |> Repo.update_all(set: [content: nil])
  end
end
