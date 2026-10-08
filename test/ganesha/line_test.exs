defmodule Ganesha.LineTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.Assistant.ProcessEventWorker
  alias Ganesha.Line

  # Standby by default, so storing is tested apart from enqueueing.
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

  test "record_event/1 enqueues an active event's job once, however often LINE redelivers it" do
    e = event(%{"mode" => "active"})
    assert :ok = Line.record_event(e)
    assert :ok = Line.record_event(e)

    stored = Repo.get_by!(Line.LineEvent, webhook_event_id: e["webhookEventId"])
    assert [_job] = all_enqueued(worker: ProcessEventWorker)
    assert_enqueued(worker: ProcessEventWorker, args: %{"line_event_id" => stored.id})
  end

  test "record_event/1 stores a standby event without enqueueing it" do
    assert :ok = Line.record_event(event())
    refute_enqueued(worker: ProcessEventWorker)
  end

  @tag :capture_log
  test "record_event/1 returns the error and stores nothing when the insert fails" do
    e = event(%{"mode" => "active"}) |> Map.delete("type")

    assert {:error, %Ecto.Changeset{}} = Line.record_event(e)
    assert Repo.aggregate(Line.LineEvent, :count) == 0
    refute_enqueued(worker: ProcessEventWorker)
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
