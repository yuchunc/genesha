defmodule Ganesha.Assistant.Tools.ProposeAttendanceDraftTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tools.ProposeAttendanceDraft
  alias Ganesha.People

  test "creates a pending attendance draft" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, _} = Assistant.append_message(thread, "user", "幫我標記今天 Lulu 缺席", nil)
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {_content, draft_id} =
      ProposeAttendanceDraft.call(%{"session_id" => 1, "student_id" => student.id, "kind" => "enrolled"}, thread)

    draft = Assistant.get_draft!(draft_id)
    assert draft.kind == "attendance"
    assert draft.parsed["session_id"] == 1
  end

  test "reports an unknown student_id instead of creating a draft against no one" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {content, draft_id} =
      ProposeAttendanceDraft.call(%{"session_id" => 1, "student_id" => 999, "kind" => "enrolled"}, thread)

    assert draft_id == nil
    assert content =~ "no student found"
  end
end
