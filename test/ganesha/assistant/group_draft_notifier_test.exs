defmodule Ganesha.Assistant.GroupDraftNotifierTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  import Ecto.Query

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Draft, GroupDraftNotifier}
  alias Ganesha.Line.Client.Mock, as: LineMock

  @teacher "Uteacher0000000000000000000000"
  @other_teacher "Uteacher2000000000000000000000"
  @group_id "Cgroupnotify000000000000000"

  setup do
    Application.put_env(:ganesha, :line_client, LineMock)
    {:ok, _} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, group} = Assistant.get_or_create_thread("group", @group_id)
    %{group: group}
  end

  defp group_draft!(group, attrs \\ %{}) do
    parsed = Map.merge(%{"note" => "8/17"}, attrs)

    {:ok, draft} =
      Assistant.create_draft(group, %{kind: "makeup_request", parsed: parsed})

    draft
  end

  test "pushes unnotified group drafts to every teacher and marks notified_at", %{group: group} do
    draft = group_draft!(group)
    {:ok, other} = Assistant.get_or_create_thread("teacher", @other_teacher)
    {:ok, _} = Assistant.set_locale(other, "en")
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(GroupDraftNotifier, %{"group_id" => @group_id})

    pushes = for {:push, {to, messages}} <- LineMock.calls(), into: %{}, do: {to, messages}
    assert Map.keys(pushes) |> Enum.sort() == Enum.sort([@teacher, @other_teacher])
    assert Enum.all?(Map.values(pushes), &(length(&1) == 2))

    # Each teacher reads the intro in their own language.
    [%{text: zh} | _] = pushes[@teacher]
    [%{text: en} | _] = pushes[@other_teacher]
    assert zh == Ganesha.Line.Labels.t(:group_drafts_push_intro, "zh-TW")
    assert en == Ganesha.Line.Labels.t(:group_drafts_push_intro, "en")

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
    end

    {:ok, group} = Assistant.get_or_create_thread("group", "Cfailgroup00000000000000")
    draft = group_draft!(group)
    Application.put_env(:ganesha, :line_client, PushFailClient)

    assert {:error, :api_error} =
             perform_job(GroupDraftNotifier, %{"group_id" => "Cfailgroup00000000000000"})

    assert is_nil(Repo.reload!(draft).notified_at)
    Application.put_env(:ganesha, :line_client, LineMock)
  end

  test "schedule/1 collapses duplicate jobs in the unique window" do
    assert {:ok, job1} = GroupDraftNotifier.schedule(@group_id)
    assert {:ok, job2} = GroupDraftNotifier.schedule(@group_id)
    assert job1.id == job2.id
  end

  test "pushes 12 and enqueues a follow-up for the rest", %{group: group} do
    drafts = for n <- 1..13, do: group_draft!(group, %{"note" => "#{n}"})
    Process.delete(:line_client_mock_calls)

    assert :ok = perform_job(GroupDraftNotifier, %{"group_id" => @group_id})

    notified = Enum.count(drafts, &Repo.reload!(&1).notified_at)
    assert notified == 12
    assert_enqueued(worker: GroupDraftNotifier, args: %{"group_id" => @group_id})
  end

  test "skips drafts that are already notified", %{group: group} do
    draft = group_draft!(group)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(d in Draft, where: d.id == ^draft.id),
      set: [notified_at: now, updated_at: now]
    )

    Process.delete(:line_client_mock_calls)
    assert :ok = perform_job(GroupDraftNotifier, %{"group_id" => @group_id})
    assert LineMock.calls() == []
  end
end
