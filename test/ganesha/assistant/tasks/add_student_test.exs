defmodule Ganesha.Assistant.Tasks.AddStudentTest do
  use Ganesha.DataCase

  alias Ganesha.{People, Repo}
  alias Ganesha.Assistant.Tasks.AddStudent
  alias Ganesha.People.StudentAlias

  test "creates the student and aliases on apply" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}

    assert {:ok, %{parsed: parsed}} =
             AddStudent.propose(%{"display_name" => "Amy", "aliases" => ["小艾"]}, ctx)

    assert {:ok, {"Ganesha.People.Student", student_id}} =
             AddStudent.apply(parsed, "line:teacher")

    assert People.get_student!(student_id).display_name == "Amy"
    assert Repo.get_by(StudentAlias, student_id: student_id, alias: "小艾")
  end

  test "apply returns changeset error on duplicate alias" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}
    {:ok, student} = People.create_student(%{display_name: "Taken"})
    {:ok, _} = People.add_alias(student, "小艾")

    assert {:ok, %{parsed: parsed}} =
             AddStudent.propose(%{"display_name" => "Amy", "aliases" => ["小艾"]}, ctx)

    assert {:error, %Ecto.Changeset{}} = AddStudent.apply(parsed, "line:teacher")
    refute People.find_by_alias("Amy")
  end
end
