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

  test "append_message/4 and list_messages/1 round-trip in insertion order" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, _} = Assistant.append_message(thread, "user", "誰欠錢？", nil)
    {:ok, _} = Assistant.append_message(thread, "assistant", nil, [%{id: "t1", name: "student_balance", input: %{}}])

    assert [first, second] = Assistant.list_messages(thread)
    assert first.role == "user"
    assert first.content == "誰欠錢？"
    assert second.role == "assistant"
    assert [%{"id" => "t1", "name" => "student_balance"}] = second.tool_calls
  end

  test "append_message/4 rejects an unknown role" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert {:error, changeset} = Assistant.append_message(thread, "system", "x", nil)
    assert "is invalid" in errors_on(changeset).role
  end
end
