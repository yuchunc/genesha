defmodule Ganesha.PeopleTest do
  use Ganesha.DataCase
  alias Ganesha.People

  test "creates a student with only a display name" do
    assert {:ok, student} = People.create_student(%{display_name: "Lulu"})
    assert student.active
    assert is_nil(student.line_user_id)
  end

  test "lists active students and all students with active students first" do
    assert {:ok, active} = People.create_student(%{display_name: "Active"})
    assert {:ok, inactive} = People.create_student(%{display_name: "Inactive", active: false})

    assert People.list_active_students() == [active]
    assert People.list_students() == [active, inactive]
  end

  test "requires a display name" do
    assert {:error, cs} = People.create_student(%{})
    assert "can't be blank" in errors_on(cs).display_name
  end

  test "rejects explicit nil for database-required defaults" do
    assert {:error, cs} = People.create_student(%{display_name: "Lulu", active: nil})
    assert "can't be blank" in errors_on(cs).active
  end

  test "line_user_id is unique when present" do
    {:ok, _} = People.create_student(%{display_name: "Kelly", line_user_id: "U123"})

    assert {:error, cs} =
             People.create_student(%{display_name: "Kelly again", line_user_id: "U123"})

    assert "has already been taken" in errors_on(cs).line_user_id
  end

  test "two students may both have no line_user_id" do
    {:ok, _} = People.create_student(%{display_name: "現金學生 A"})
    assert {:ok, _} = People.create_student(%{display_name: "現金學生 B"})
  end

  test "find_by_alias/1 resolves an alias to its student" do
    {:ok, student} = People.create_student(%{display_name: "莉芸"})
    {:ok, _} = People.add_alias(student, "Liyun")

    assert %{id: id} = People.find_by_alias("Liyun")
    assert id == student.id
  end

  test "get_student!/1 preloads aliases" do
    {:ok, student} = People.create_student(%{display_name: "莉芸"})
    {:ok, _} = People.add_alias(student, "Liyun")

    loaded = People.get_student!(student.id)
    assert loaded.id == student.id
    assert [%{alias: "Liyun"}] = loaded.aliases
  end

  test "an alias cannot point at two students" do
    {:ok, a} = People.create_student(%{display_name: "A"})
    {:ok, b} = People.create_student(%{display_name: "B"})
    {:ok, _} = People.add_alias(a, "shared")

    assert {:error, cs} = People.add_alias(b, "shared")
    assert "has already been taken" in errors_on(cs).alias
  end

  test "updates and changes a student" do
    {:ok, student} = People.create_student(%{display_name: "Original"})

    assert {:ok, updated} =
             People.update_student(student, %{
               display_name: "Updated",
               line_user_id: "U999",
               active: false
             })

    assert updated.display_name == "Updated"
    assert updated.line_user_id == "U999"
    refute updated.active

    changeset = People.change_student(updated, %{display_name: "Changed"})
    assert changeset.valid?
    assert changeset.changes.display_name == "Changed"
  end

  test "find_by_alias/1 and find_by_line_user_id/1 return nil when unknown" do
    assert People.find_by_alias("nobody") == nil
    assert People.find_by_alias(nil) == nil
    assert People.find_by_line_user_id("Unknown") == nil
    assert People.find_by_line_user_id(nil) == nil
  end
end
