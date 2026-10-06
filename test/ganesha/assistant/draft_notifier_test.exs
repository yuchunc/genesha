defmodule Ganesha.Assistant.DraftNotifierTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  import Ecto.Query

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Draft, DraftNotifier}
  alias Ganesha.Line.Client.Mock, as: LineMock
  alias Ganesha.Line.Labels

  @teacher "Uteacher0000000000000000000000"
  @other_teacher "Uteacher2000000000000000000000"
  @group_id "Cgroupnotify000000000000000"
  @student_line_id "Ustudentnotify0000000000000000"

  setup do
    Application.put_env(:ganesha, :line_client, LineMock)
    {:ok, _} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, group} = Assistant.get_or_create_thread("group", @group_id)
    {:ok, student_chat} = Assistant.get_or_create_thread("user", @student_line_id)
    %{group: group, student_chat: student_chat}
  end

  defp group_draft!(group, attrs \\ %{}) do
    parsed = Map.merge(%{"note" => "8/17"}, attrs)
    {:ok, draft} = Assistant.create_draft(group, %{kind: "makeup_request", parsed: parsed})
    draft
  end

  defp signup_draft!(student_chat) do
    {:ok, draft} =
      Assistant.create_draft(student_chat, %{
        kind: "signup_request",
        parsed: %{
          "note" => "想報名週一晚上",
          "student_id" => nil,
          "student_name" => nil,
          "line_user_id" => @student_line_id,
          "line_name" => "小美",
          "new" => true
        }
      })

    draft
  end

  defp backdate!(draft, seconds) do
    at = DateTime.utc_now() |> DateTime.add(-seconds) |> DateTime.truncate(:second)
    Repo.update_all(from(d in Draft, where: d.id == ^draft.id), set: [inserted_at: at])
    Repo.reload!(draft)
  end

  defp scheduled_at(job),
    do: Repo.get!(Oban.Job, job.id).scheduled_at |> DateTime.truncate(:second)

  defp intros do
    for {:push, {to, [%{text: text} | _]}} <- LineMock.calls(), into: %{}, do: {to, text}
  end

  test "pushes a group's unnotified drafts to every teacher, each in her language", %{
    group: group
  } do
    draft = group_draft!(group)
    {:ok, other} = Assistant.get_or_create_thread("teacher", @other_teacher)
    {:ok, _} = Assistant.set_locale(other, "en")
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(DraftNotifier, %{"thread_id" => group.id})

    assert intros() == %{
             @teacher => Labels.t(:group_drafts_push_intro, "zh-TW"),
             @other_teacher => Labels.t(:group_drafts_push_intro, "en")
           }

    assert Enum.all?(LineMock.calls(), fn {:push, {_to, messages}} -> length(messages) == 2 end)
    assert Repo.reload!(draft).notified_at != nil
  end

  test "pushes a Student chat's sign-up request to every teacher with the student intro", %{
    student_chat: student_chat
  } do
    draft = signup_draft!(student_chat)
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(DraftNotifier, %{"thread_id" => student_chat.id})

    assert intros() == %{
             @teacher => Labels.t(:student_drafts_push_intro, "zh-TW"),
             @other_teacher => Labels.t(:student_drafts_push_intro, "zh-TW")
           }

    assert Repo.reload!(draft).notified_at != nil
  end

  test "push failure leaves notified_at nil" do
    defmodule PushFailClient do
      @behaviour Ganesha.Line.ClientBehaviour

      def reply(reply_token, messages),
        do: Ganesha.Line.Client.Mock.reply(reply_token, messages)

      def push(_to, _messages), do: {:error, :api_error}
      def loading(chat_id, seconds), do: Ganesha.Line.Client.Mock.loading(chat_id, seconds)

      def validate_reply(messages), do: Ganesha.Line.Client.Mock.validate_reply(messages)

      def get_group_member(group_id, user_id),
        do: Ganesha.Line.Client.Mock.get_group_member(group_id, user_id)

      def get_group_summary(group_id),
        do: Ganesha.Line.Client.Mock.get_group_summary(group_id)

      def get_profile(user_id), do: Ganesha.Line.Client.Mock.get_profile(user_id)
    end

    {:ok, group} = Assistant.get_or_create_thread("group", "Cfailgroup00000000000000")
    draft = group_draft!(group)
    Application.put_env(:ganesha, :line_client, PushFailClient)

    assert {:error, :api_error} = perform_job(DraftNotifier, %{"thread_id" => group.id})

    assert is_nil(Repo.reload!(draft).notified_at)
    Application.put_env(:ganesha, :line_client, LineMock)
  end

  test "a group keeps one job for three minutes from its first draft", %{group: group} do
    assert {:ok, job1} = DraftNotifier.schedule(group)
    assert {:ok, job2} = DraftNotifier.schedule(group)

    assert job1.id == job2.id
    assert_in_delta DateTime.diff(job1.scheduled_at, DateTime.utc_now()), 180, 5
    stored = Repo.get!(Oban.Job, job1.id).scheduled_at
    assert_in_delta DateTime.diff(stored, job1.scheduled_at), 0, 1
  end

  test "a Student chat's job waits five minutes from its latest unnotified draft", %{
    student_chat: student_chat
  } do
    # The first draft came four minutes ago.
    first = student_chat |> signup_draft!() |> backdate!(240)
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    [job] = all_enqueued(worker: DraftNotifier)
    assert scheduled_at(job) == DateTime.add(first.inserted_at, 300)

    # A turn without a new draft does not move it.
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    assert [%{id: same_id}] = all_enqueued(worker: DraftNotifier)
    assert same_id == job.id
    assert scheduled_at(job) == DateTime.add(first.inserted_at, 300)

    # A newer draft moves it to five minutes after that draft.
    newer = signup_draft!(student_chat)
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    assert [%{id: ^same_id}] = all_enqueued(worker: DraftNotifier)
    assert scheduled_at(job) == DateTime.add(newer.inserted_at, 300)
  end

  test "a Student chat gets a new job once the waiting one has started", %{
    student_chat: student_chat
  } do
    signup_draft!(student_chat)
    assert {:ok, job1} = DraftNotifier.schedule(student_chat)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job1.id), set: [state: "executing"])

    assert {:ok, job2} = DraftNotifier.schedule(student_chat)
    assert job2.id != job1.id
  end

  test "schedule_if_pending/1 schedules only when a draft is waiting for the teachers", %{
    student_chat: student_chat
  } do
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    refute_enqueued(worker: DraftNotifier)

    signup_draft!(student_chat)
    assert :ok = DraftNotifier.schedule_if_pending(student_chat)
    assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => student_chat.id})
  end

  test "pushes 12 and enqueues a follow-up for the rest", %{group: group} do
    drafts = for n <- 1..13, do: group_draft!(group, %{"note" => "#{n}"})
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(DraftNotifier, %{"thread_id" => group.id})

    assert Enum.count(drafts, &Repo.reload!(&1).notified_at) == 12
    assert_enqueued(worker: DraftNotifier, args: %{"thread_id" => group.id})
  end

  test "skips drafts that are already notified", %{group: group} do
    draft = group_draft!(group)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(d in Draft, where: d.id == ^draft.id),
      set: [notified_at: now, updated_at: now]
    )

    Process.delete(:line_client_mock_calls)
    assert :ok = perform_job(DraftNotifier, %{"thread_id" => group.id})
    assert LineMock.calls() == []
  end
end
