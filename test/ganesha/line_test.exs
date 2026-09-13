defmodule Ganesha.LineTest do
  use Ganesha.DataCase
  alias Ganesha.Line

  # `mode: "standby"` here is deliberate: `record_event/1` only attempts to
  # enqueue `Ganesha.Assistant.ProcessEventWorker` for `mode: "active"`
  # events, and that worker does not exist until Task 15. Active-mode
  # enqueueing is exercised there instead, once it exists — see
  # `enqueue_teacher_message/1` in `process_event_worker_test.exs`.
  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "webhookEventId" => "01#{System.unique_integer([:positive])}",
        "type" => "message",
        "mode" => "standby",
        "source" => %{"type" => "user", "userId" => "Uteacher"},
        "message" => %{"type" => "text", "text" => "hi"}
      },
      overrides
    )
  end

  test "record_event/1 persists a new event" do
    assert :ok = Line.record_event(event())
  end

  test "record_event/1 is idempotent on webhook_event_id" do
    e = event()
    assert :ok = Line.record_event(e)
    assert :ok = Line.record_event(e)
    assert Repo.aggregate(Line.LineEvent, :count) == 1
  end

  test "get_event!/1 and mark_processed/1" do
    :ok = Line.record_event(event(%{"webhookEventId" => "mark-me"}))
    stored = Repo.get_by!(Line.LineEvent, webhook_event_id: "mark-me")

    loaded = Line.get_event!(stored.id)
    assert is_nil(loaded.processed_at)

    Line.mark_processed(loaded)
    assert %{processed_at: %DateTime{}} = Line.get_event!(stored.id)
  end
end
