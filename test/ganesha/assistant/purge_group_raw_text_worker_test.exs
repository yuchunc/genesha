defmodule Ganesha.Assistant.PurgeGroupRawTextWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Line, Repo}
  alias Ganesha.Assistant.PurgeGroupRawTextWorker

  defp insert_old_line_event(source_type, source_id) do
    old = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60, :second) |> DateTime.truncate(:second)

    {:ok, event} =
      %Line.LineEvent{}
      |> Line.LineEvent.changeset(%{
        webhook_event_id: "evt-#{System.unique_integer([:positive])}",
        source_type: source_type,
        source_id: source_id,
        raw_type: "message",
        payload: %{"message" => %{"text" => "secret"}}
      })
      |> Repo.insert()

    event |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
  end

  defp insert_old_message(thread, content) do
    old = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60, :second) |> DateTime.truncate(:second)
    {:ok, message} = Assistant.append_message(thread, "user", content, nil)
    message |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()
  end

  test "purges group line_events payload older than 24h" do
    event = insert_old_line_event("group", "Cabc")
    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})
    assert Line.get_event!(event.id).payload == %{"purged" => true}
  end

  test "does not purge any teacher's own 1:1 line_events" do
    events = for id <- Line.teacher_ids(), do: insert_old_line_event("user", id)
    assert length(events) == 2
    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    for event <- events do
      assert Line.get_event!(event.id).payload == %{"message" => %{"text" => "secret"}}
    end
  end

  test "purges group thread message content older than 24h, leaves the teacher thread alone" do
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")

    {:ok, teacher_thread} =
      Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")

    group_message = insert_old_message(group_thread, "2.Lulu （Line pay 1200元）")
    teacher_message = insert_old_message(teacher_thread, "誰欠錢？")

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert Repo.get!(Assistant.Message, group_message.id).content == nil
    assert Repo.get!(Assistant.Message, teacher_message.id).content == "誰欠錢？"
  end

  test "leaves recent group messages untouched" do
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, recent} = Assistant.append_message(group_thread, "user", "剛剛的訊息", nil)

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert Repo.get!(Assistant.Message, recent.id).content == "剛剛的訊息"
  end

  test "clears a group message's sender with its text after 24h" do
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    old = DateTime.utc_now() |> DateTime.add(-25 * 60 * 60, :second) |> DateTime.truncate(:second)

    {:ok, message} =
      Assistant.append_message(group_thread, "user", "hi", nil,
        sender_id: "Umei",
        sender_name: "小美"
      )

    message |> Ecto.Changeset.change(inserted_at: old) |> Repo.update!()

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert %{content: nil, sender_id: nil, sender_name: nil} =
             Repo.get!(Assistant.Message, message.id)
  end

  test "keeps everything when purge_raw_text is off (dev)" do
    line_config = Application.fetch_env!(:ganesha, :line)
    on_exit(fn -> Application.put_env(:ganesha, :line, line_config) end)
    Application.put_env(:ganesha, :line, Keyword.put(line_config, :purge_raw_text, false))

    event = insert_old_line_event("group", "Cabc")
    {:ok, group_thread} = Assistant.get_or_create_thread("group", "Cabc")
    message = insert_old_message(group_thread, "2.Lulu （Line pay 1200元）")

    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})

    assert Line.get_event!(event.id).payload == %{"message" => %{"text" => "secret"}}
    assert Repo.get!(Assistant.Message, message.id).content == "2.Lulu （Line pay 1200元）"
  end
end
