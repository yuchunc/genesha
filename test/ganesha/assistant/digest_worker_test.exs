defmodule Ganesha.Assistant.DigestWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.{Digest, DigestWorker}
  alias Ganesha.Assistant.Provider.Mock

  test "writes yesterday's digest for the Teacher chat and none for the Group chat" do
    # 12:00 Asia/Taipei yesterday.
    yesterday_noon = DateTime.new!(Date.add(Clock.today(), -1), ~T[04:00:00], "Etc/UTC")
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")

    for thread <- [teacher, group] do
      {:ok, message} = Assistant.append_message(thread, "user", "昨天的事", nil)
      message |> Ecto.Changeset.change(inserted_at: yesterday_noon) |> Repo.update!()
    end

    Mock.stub(fn _messages, [], _opts -> {:ok, %{text: "摘要", tool_calls: []}} end)

    assert :ok = perform_job(DigestWorker, %{})

    assert [%Digest{thread_id: thread_id, content: "摘要"}] =
             Repo.all(from d in Digest, where: d.kind == "daily")

    assert thread_id == teacher.id
    refute Repo.exists?(from d in Digest, where: d.thread_id == ^group.id)
  end
end
