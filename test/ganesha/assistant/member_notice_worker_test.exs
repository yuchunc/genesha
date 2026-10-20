defmodule Ganesha.Assistant.MemberNoticeWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.{GroupMembers, MemberNoticeWorker}
  alias Ganesha.Line.Client.Mock, as: LineMock
  alias Ganesha.People.{LineMember, Student}

  @teacher "Uteacher0000000000000000000000"
  @other_teacher "Uteacher2000000000000000000000"

  @created %{
    "kind" => "created",
    "line_user_id" => "U1",
    "display_name" => "小美",
    "student_id" => 7,
    "student_name" => "小美"
  }

  setup do
    Application.put_env(:ganesha, :line_client, LineMock)
    {:ok, other} = Assistant.get_or_create_thread("teacher", @other_teacher)
    {:ok, _} = Assistant.set_locale(other, "en")
    :ok
  end

  test "pushes the created notice to every teacher in her locale" do
    assert :ok = perform_job(MemberNoticeWorker, @created)

    assert [{:push, {@teacher, [zh]}}, {:push, {@other_teacher, [en]}}] = LineMock.calls()
    assert zh.altText == "新增學生 小美（LINE：小美）"
    assert en.altText == "Added student 小美 (LINE: 小美)"
  end

  test "fails only when every push failed" do
    Process.put(:line_client_mock_push, {:error, :api_error})
    assert {:error, :api_error} = perform_job(MemberNoticeWorker, @created)
    assert length(LineMock.calls()) == 2

    defmodule FirstPushFails do
      def push(to, messages) do
        Ganesha.Line.Client.Mock.push(to, messages)
        if to == "Uteacher0000000000000000000000", do: {:error, :api_error}, else: :ok
      end
    end

    Process.delete(:line_client_mock_push)
    Application.put_env(:ganesha, :line_client, FirstPushFails)
    assert :ok = perform_job(MemberNoticeWorker, @created)
    Application.put_env(:ganesha, :line_client, LineMock)
  end

  test "args/3 keeps up to three candidates and counts the rest" do
    candidates = for id <- 1..5, do: %Student{id: id, display_name: "Amy #{id}"}

    assert MemberNoticeWorker.args({:unsure, candidates}, "U1", "Amy") == %{
             "kind" => "unsure",
             "line_user_id" => "U1",
             "display_name" => "Amy",
             "candidates" => [
               %{"id" => 1, "name" => "Amy 1"},
               %{"id" => 2, "name" => "Amy 2"},
               %{"id" => 3, "name" => "Amy 3"}
             ],
             "more" => 2
           }

    assert MemberNoticeWorker.args({:linked, %Student{id: 9, display_name: "Amy"}}, "U1", "amy") ==
             %{
               "kind" => "linked",
               "line_user_id" => "U1",
               "display_name" => "amy",
               "student_id" => 9,
               "student_name" => "Amy"
             }
  end

  test "GroupMembers.resolve enqueues one notice for a created student" do
    assert {:created, s} = GroupMembers.resolve("U1", "小美")

    assert_enqueued(
      worker: MemberNoticeWorker,
      args: %{"kind" => "created", "student_id" => s.id, "line_user_id" => "U1"}
    )

    assert [_] = all_enqueued(worker: MemberNoticeWorker)
  end

  test "GroupMembers.resolve enqueues a notice for a linked or unsure member" do
    {:ok, amy} = People.create_student(%{display_name: "Amy"})
    assert {:linked, _} = GroupMembers.resolve("U1", "amy")

    assert_enqueued(
      worker: MemberNoticeWorker,
      args: %{"kind" => "linked", "student_id" => amy.id, "line_user_id" => "U1"}
    )

    {:ok, _} = People.create_student(%{display_name: "Bo"})
    {:ok, _} = People.create_student(%{display_name: "Bo"})
    assert {:unsure, _} = GroupMembers.resolve("U2", "Bo")

    assert_enqueued(
      worker: MemberNoticeWorker,
      args: %{"kind" => "unsure", "line_user_id" => "U2"}
    )
  end

  test "GroupMembers.resolve skips teachers and enqueues nothing for known or pending" do
    assert :skipped = GroupMembers.resolve(@teacher, "老師")

    {:ok, _} = People.create_student(%{display_name: "小美", line_user_id: "U1"})
    assert {:known, _} = GroupMembers.resolve("U1", "小美")

    Repo.insert!(%LineMember{line_user_id: "U2", display_name: "Amy", state: "unsure"})
    assert :pending = GroupMembers.resolve("U2", "Amy")

    refute_enqueued(worker: MemberNoticeWorker)
  end
end
