defmodule Ganesha.PeopleTest do
  use Ganesha.DataCase
  alias Ganesha.People

  test "creates a student with only a display name" do
    assert {:ok, student} = People.create_student(%{display_name: "Lulu"})
    assert student.active
    assert is_nil(student.line_user_id)
  end

  test "requires a display name" do
    assert {:error, cs} = People.create_student(%{})
    assert "can't be blank" in errors_on(cs).display_name
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

  test "an alias cannot point at two students" do
    {:ok, a} = People.create_student(%{display_name: "A"})
    {:ok, b} = People.create_student(%{display_name: "B"})
    {:ok, _} = People.add_alias(a, "shared")

    assert {:error, cs} = People.add_alias(b, "shared")
    assert "has already been taken" in errors_on(cs).alias
  end

  test "find_by_alias/1 and find_by_line_user_id/1 return nil when unknown" do
    assert People.find_by_alias("nobody") == nil
    assert People.find_by_line_user_id("Unknown") == nil
    assert People.find_by_line_user_id(nil) == nil
  end
end
