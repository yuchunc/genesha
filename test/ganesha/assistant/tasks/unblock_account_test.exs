defmodule Ganesha.Assistant.Tasks.UnblockAccountTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Line}
  alias Ganesha.Assistant.Tasks.UnblockAccount

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher0000000000000000000000")
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})
    %{ctx: %{thread: teacher, locale: "zh-TW", today: ~D[2026-10-05]}}
  end

  test "propose copies the label; apply unblocks", c do
    assert {:ok, %{student_id: nil, parsed: parsed}} =
             UnblockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    assert parsed == %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    assert {:ok, {nil, nil}} = UnblockAccount.apply(parsed, "line:teacher")
    refute Line.blocked?("sender", "Umei")
  end

  test "propose refuses an account that is not blocked", c do
    assert {:error, _} = UnblockAccount.propose(%{"kind" => "sender", "line_id" => "Uzhe"}, c.ctx)
    assert {:error, _} = UnblockAccount.propose(%{"kind" => "group", "line_id" => "Umei"}, c.ctx)
  end

  test "apply after the row is gone fails as not blocked", c do
    {:ok, %{parsed: parsed}} =
      UnblockAccount.propose(%{"kind" => "sender", "line_id" => "Umei"}, c.ctx)

    :ok = Line.unblock_account("sender", "Umei")
    assert {:error, :not_blocked} = UnblockAccount.apply(parsed, "line:teacher")
  end

  test "summary says who or what is read again" do
    sender = %{"kind" => "sender", "line_id" => "Umei", "label" => "小美"}
    group = %{"kind" => "group", "line_id" => "Cabc", "label" => "瑜伽週三班"}

    assert UnblockAccount.summary(sender, "zh-TW") == "解除封鎖 小美：之後會再讀取這個人在群組中的訊息"
    assert UnblockAccount.summary(sender, "en") == "Unblock 小美: their group messages will be read again"
    assert UnblockAccount.summary(group, "zh-TW") == "解除封鎖群組「瑜伽週三班」：之後會再讀取這個群組"
    assert UnblockAccount.summary(group, "en") == ~s(Unblock group "瑜伽週三班": read this group again)
  end
end
