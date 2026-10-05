defmodule Ganesha.Assistant.Tasks.ListeningTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.Tasks.Listening

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    %{ctx: %{thread: teacher, locale: "zh-TW", today: ~D[2026-10-05]}}
  end

  defp post(thread, sender_id, sender_name) do
    {:ok, _} =
      Assistant.append_message(thread, "user", "hi", nil,
        sender_id: sender_id,
        sender_name: sender_name
      )
  end

  test "says so when the bot has no group yet", c do
    assert {:ok, %{data: data}} = Listening.answer(%{}, c.ctx)
    assert data =~ "none yet"
    assert data =~ "Blocked: nobody."
  end

  test "lists each group by name, its senders newest first, and the blocklist", c do
    Process.put(:line_client_mock_group_summary, {:ok, %{"groupName" => "瑜伽週三班"}})
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    post(group, "Umei", "小美")
    post(group, "Uzhe", "阿哲")
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Uzhe", label: "阿哲"})

    {:ok, %{data: data}} = Listening.answer(%{}, c.ctx)

    assert data =~ "Group 瑜伽週三班 (id Cabc), listening"
    assert data =~ "小美 (id Umei)"
    assert data =~ ~r/阿哲 \(id Uzhe\), last seen [^\n]*, blocked/
    assert data =~ "sender 阿哲 (id Uzhe)"

    {zhe_at, _} = :binary.match(data, "(id Uzhe)")
    {mei_at, _} = :binary.match(data, "(id Umei)")
    assert zhe_at < mei_at
  end

  test "marks a blocked group", c do
    {:ok, _} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "測試群組"})

    {:ok, %{data: data}} = Listening.answer(%{}, c.ctx)
    assert data =~ "(id Cabc), blocked"
  end

  test "find_group_sender/1 finds a sender from any group, nil otherwise" do
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    post(group, "Umei", "小美")

    assert %{sender_id: "Umei", sender_name: "小美"} = Assistant.find_group_sender("Umei")
    assert Assistant.find_group_sender("Unobody") == nil
  end
end
