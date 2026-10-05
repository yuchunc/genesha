defmodule Ganesha.Assistant.PurgeGroupRawTextWorker do
  @moduledoc """
  Hourly sweep enforcing the 24h raw-text retention window for anything
  sourced from the group, or from an unrecognised 1:1 sender — the
  teacher's own thread and `drafts.parsed` are exempt (spec §7). A group
  message's sender goes with its text. Off when `:line, :purge_raw_text` is
  false, which only dev sets (spec 2026-10-05 §5).
  """
  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Ganesha.Assistant.{Message, Thread}
  alias Ganesha.Line.LineEvent
  alias Ganesha.Repo

  @retention_seconds 24 * 60 * 60

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if purge_raw_text?() do
      cutoff = DateTime.utc_now() |> DateTime.add(-@retention_seconds, :second)

      purge_line_events(cutoff, Ganesha.Line.teacher_ids())
      purge_group_messages(cutoff)
    end

    :ok
  end

  defp purge_raw_text? do
    Application.fetch_env!(:ganesha, :line) |> Keyword.get(:purge_raw_text, true)
  end

  defp purge_line_events(cutoff, teacher_ids) do
    from(e in LineEvent,
      where: e.inserted_at < ^cutoff,
      where: not (e.source_type == "user" and e.source_id in ^teacher_ids)
    )
    |> Repo.update_all(set: [payload: %{"purged" => true}])
  end

  defp purge_group_messages(cutoff) do
    group_thread_ids = from(t in Thread, where: t.source_type == "group", select: t.id)

    from(m in Message,
      where: m.thread_id in subquery(group_thread_ids),
      where: m.inserted_at < ^cutoff,
      where: not is_nil(m.content) or not is_nil(m.sender_id) or not is_nil(m.sender_name)
    )
    |> Repo.update_all(set: [content: nil, sender_id: nil, sender_name: nil])
  end
end
