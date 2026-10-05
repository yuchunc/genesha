defmodule Ganesha.Line.BlockedAccountsTest do
  use Ganesha.DataCase

  alias Ganesha.Line

  test "a block applies to its kind only" do
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})

    assert Line.blocked?("sender", "Umei")
    refute Line.blocked?("group", "Umei")
    refute Line.blocked?("sender", "Uother")
    refute Line.blocked?("sender", nil)
  end

  test "blocking twice reports already blocked" do
    {:ok, _} = Line.block_account(%{kind: "group", line_id: "Cabc", label: "瑜伽週三班"})

    assert {:error, :already_blocked} =
             Line.block_account(%{kind: "group", line_id: "Cabc", label: "瑜伽週三班"})
  end

  test "unblock deletes the row; a second unblock reports not blocked" do
    {:ok, _} = Line.block_account(%{kind: "sender", line_id: "Umei", label: "小美"})

    assert :ok = Line.unblock_account("sender", "Umei")
    refute Line.blocked?("sender", "Umei")
    assert Line.get_blocked_account("sender", "Umei") == nil
    assert {:error, :not_blocked} = Line.unblock_account("sender", "Umei")
  end

  test "rejects an unknown kind" do
    assert {:error, %Ecto.Changeset{}} =
             Line.block_account(%{kind: "room", line_id: "Rr", label: "x"})
  end

  test "lists newest first" do
    {:ok, first} = Line.block_account(%{kind: "sender", line_id: "U1", label: "一"})
    {:ok, second} = Line.block_account(%{kind: "sender", line_id: "U2", label: "二"})

    assert Enum.map(Line.list_blocked_accounts(), & &1.id) == [second.id, first.id]
  end
end
