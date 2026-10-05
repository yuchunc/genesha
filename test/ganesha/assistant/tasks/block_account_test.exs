defmodule Ganesha.Assistant.Tasks.BlockAccountTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.Tasks.BlockAccount

  @teacher "Uteacher0000000000000000000000"

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", @teacher)
    {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")

    for {id, name} <- [{"Umei", "小美"}, {@teacher, "老師"}] do
      {:ok, _} = Assistant.append_message(group, "user", "hi", nil, sender_id: id, sender_name: name)
    end

    Process.put(:line_client_mock_group_summary, {:ok, %{"groupName" => "瑜伽週三班"}})
    %{ctx: %{thread: teacher, locale: "zh-TW", today: ~D[2026-10-05]}}
  end

  test "propose captures the sender's name; apply blocks them", c do
    assert {:ok, %{student_id: nil, parsed: parsed}} =
             BlockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    assert parsed == %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    refute Line.blocked?("sender", "Umei")

    assert {:ok, {"Ganesha.Line.BlockedAccount", id}} = BlockAccount.apply(parsed, "line:teacher")
    assert %{id: ^id} = Line.get_blocked_account("sender", "Umei")
  end

  test "propose names a group by its LINE name", c do
    assert {:ok, %{parsed: %{"kind" => "group", "label" => "瑜伽週三班"}}} =
             BlockAccount.propose(%{"kind" => "group", "line_id" => "Cabc"}, c.ctx)
  end

  test "propose refuses a teacher, unknown ids, a bad kind, and an account already blocked", c do
    assert {:error, teacher_error} =
             BlockAccount.propose(%{"kind" => "sender", "line_id" => @teacher}, c.ctx)

    assert teacher_error =~ "teacher"

    assert {:error, _} = BlockAccount.propose(%{"kind" => "sender", "line_id" => "Unobody"}, c.ctx)
    assert {:error, _} = BlockAccount.propose(%{"kind" => "group", "line_id" => "Cnowhere"}, c.ctx)
    assert {:error, _} = BlockAccount.propose(%{"kind" => "room", "line_id" => "Rr"}, c.ctx)

    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})
    assert {:error, _} = BlockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)
  end

  test "a second apply of the same Draft fails as already blocked", c do
    {:ok, %{parsed: parsed}} =
      BlockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    {:ok, _} = BlockAccount.apply(parsed, "line:teacher")
    assert {:error, :already_blocked} = BlockAccount.apply(parsed, "line:teacher")
  end

  test "summary says who or what stops being read" do
    sender = %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    group = %{"kind" => "group", "line_id" => "Cabc", "label" => "瑜伽週三班"}

    assert BlockAccount.summary(sender, "zh-TW") == "封鎖 小美：之後所有群組中這個人的訊息都不再讀取"
    assert BlockAccount.summary(sender, "en") == "Block 小美: their messages in every group will be ignored"
    assert BlockAccount.summary(group, "zh-TW") == "封鎖群組「瑜伽週三班」：之後不再讀取這個群組"
    assert BlockAccount.summary(group, "en") == ~s(Block group "瑜伽週三班": stop reading this group)
  end
end
