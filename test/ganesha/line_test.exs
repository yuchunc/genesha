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

  test "earlier_unprocessed?/1 never holds back an event without a chat" do
    for id <- ["no-chat-1", "no-chat-2"] do
      :ok = Line.record_event(event(%{"webhookEventId" => id}) |> Map.delete("source"))
    end

    refute Line.earlier_unprocessed?(Repo.get_by!(Line.LineEvent, webhook_event_id: "no-chat-2"))
  end

  test "record_event/1 routes source_id to the group, not the per-message sender" do
    e =
      event(%{
        "webhookEventId" => "group-event",
        "source" => %{"type" => "group", "groupId" => "Cgroup", "userId" => "Usender"}
      })

    assert :ok = Line.record_event(e)
    stored = Repo.get_by!(Line.LineEvent, webhook_event_id: "group-event")
    assert stored.source_type == "group"
    assert stored.source_id == "Cgroup"
  end

  test "record_event/1 routes source_id to the room" do
    e =
      event(%{
        "webhookEventId" => "room-event",
        "source" => %{"type" => "room", "roomId" => "Rroom"}
      })

    assert :ok = Line.record_event(e)
    stored = Repo.get_by!(Line.LineEvent, webhook_event_id: "room-event")
    assert stored.source_type == "room"
    assert stored.source_id == "Rroom"
  end

  test "record_event/1 routes source_id to the user for a 1:1 message" do
    e = event(%{"webhookEventId" => "user-event"})

    assert :ok = Line.record_event(e)
    stored = Repo.get_by!(Line.LineEvent, webhook_event_id: "user-event")
    assert stored.source_type == "user"
    assert stored.source_id == "Uteacher"
  end

  test "record_event/1 stores group and room events without their reply token" do
    for {type, key, id} <- [{"group", "groupId", "Cg"}, {"room", "roomId", "Rr"}] do
      e =
        event(%{
          "replyToken" => "rt",
          "source" => %{"type" => type, key => id, "userId" => "Ustudent"}
        })

      :ok = Line.record_event(e)
      stored = Repo.get_by!(Line.LineEvent, webhook_event_id: e["webhookEventId"])
      refute Map.has_key?(stored.payload, "replyToken")
    end
  end

  test "record_event/1 keeps a 1:1 event's reply token" do
    e = event(%{"replyToken" => "rt"})
    :ok = Line.record_event(e)

    assert Repo.get_by!(Line.LineEvent, webhook_event_id: e["webhookEventId"]).payload[
             "replyToken"
           ] == "rt"
  end

  test "group_name/1 is the group's LINE name" do
    Process.put(:line_client_mock_group_summary, {:ok, %{"groupName" => "瑜伽週三班"}})
    assert Line.group_name("Cabc") == "瑜伽週三班"
  end

  @tag :capture_log
  test "group_name/1 falls back to the id when LINE can't say" do
    Process.put(:line_client_mock_group_summary, {:error, {404, %{}}})
    assert Line.group_name("Cabc") == "Cabc"
  end
end
