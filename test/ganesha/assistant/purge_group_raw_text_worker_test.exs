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

  test "does not purge the teacher's own 1:1 line_events" do
    teacher_id = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:teacher_line_user_id)
    event = insert_old_line_event("user", teacher_id)
    assert :ok = perform_job(PurgeGroupRawTextWorker, %{})
    assert Line.get_event!(event.id).payload == %{"message" => %{"text" => "secret"}}
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
end
