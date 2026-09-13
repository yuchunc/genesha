defmodule Ganesha.AssistantTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant

  test "get_or_create_thread/2 creates once and reuses on repeat calls" do
    assert {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert {:ok, same} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert thread.id == same.id
  end

  test "get_or_create_thread/2 keeps group and teacher threads separate per source_id" do
    assert {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    assert {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Cabc")
    refute group.id == teacher.id
  end

  test "get_or_create_thread/2 rejects an unknown source_type" do
    assert {:error, changeset} = Assistant.get_or_create_thread("student", "U1")
    assert "is invalid" in errors_on(changeset).source_type
  end
end
