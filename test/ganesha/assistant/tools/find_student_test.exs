defmodule Ganesha.Assistant.Tools.FindStudentTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.FindStudent
  alias Ganesha.People

  test "resolves an alias" do
    {:ok, student} = People.create_student(%{display_name: "莉芸"})
    {:ok, _} = People.add_alias(student, "Liyun")

    {content, draft_id} = FindStudent.call(%{"query" => "Liyun"}, nil)
    assert draft_id == nil
    assert %{"id" => id, "display_name" => "莉芸"} = Jason.decode!(content)
    assert id == student.id
  end

  test "falls back to an exact display name match" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {content, _} = FindStudent.call(%{"query" => "Lulu"}, nil)
    assert %{"id" => id} = Jason.decode!(content)
    assert id == student.id
  end

  test "reports ambiguous display name matches" do
    {:ok, first} = People.create_student(%{display_name: "Lulu"})
    {:ok, second} = People.create_student(%{display_name: "Lulu"})

    {content, nil} = FindStudent.call(%{"query" => "Lulu"}, nil)
    assert content =~ "multiple students found matching \"Lulu\""
    assert content =~ Integer.to_string(first.id)
    assert content =~ Integer.to_string(second.id)
  end

  test "reports no match" do
    {content, nil} = FindStudent.call(%{"query" => "nobody"}, nil)
    assert content == "no student found matching \"nobody\""
  end
end
