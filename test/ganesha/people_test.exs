defmodule Ganesha.PeopleTest do
  use Ganesha.DataCase
  alias Ganesha.People
  alias Ganesha.People.{LineMember, Student}

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

  describe "resolve_line_member/2" do
    test "an already linked student is known" do
      s = student!(%{display_name: "小美", line_user_id: "U1"})
      assert {:known, %{id: id}} = People.resolve_line_member("U1", "別的名字")
      assert id == s.id
    end

    test "a not_student member stays not a student" do
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "老公", state: "not_student"})
      assert :not_student = People.resolve_line_member("U1", "老公")
      assert Repo.aggregate(Student, :count) == 0
    end

    test "an unsure member is pending" do
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})
      assert :pending = People.resolve_line_member("U1", "Amy")
    end

    test "no name match creates a linked student named after LINE" do
      assert {:created, %Student{display_name: "小美", line_user_id: "U1"}} =
               People.resolve_line_member("U1", " 小美 ")
    end

    test "one active unlinked match is linked" do
      s = student!(%{display_name: "Amy"})
      assert {:linked, %{id: id, line_user_id: "U1"}} = People.resolve_line_member("U1", "Amy")
      assert id == s.id
    end

    test "normalizes before matching" do
      s = student!(%{display_name: "ａｍｙ Chen"})
      assert {:linked, %{id: id}} = People.resolve_line_member("U1", "AMY CHEN ")
      assert id == s.id
    end

    test "an alias alone matches" do
      t = student!(%{display_name: "林美玲"})
      {:ok, _} = People.add_alias(t, "阿美")
      assert {:linked, %{id: id}} = People.resolve_line_member("U2", "阿美")
      assert id == t.id
    end

    test "several matches are unsure and recorded" do
      a = student!(%{display_name: "Amy"})
      b = student!(%{display_name: "amy"})
      assert {:unsure, candidates} = People.resolve_line_member("U1", "Amy")
      assert Enum.map(candidates, & &1.id) == [a.id, b.id]
      assert %LineMember{state: "unsure", display_name: "Amy"} = People.get_line_member("U1")
    end

    test "an inactive single match is unsure" do
      student!(%{display_name: "Amy", active: false})
      assert {:unsure, [_]} = People.resolve_line_member("U1", "Amy")
    end

    test "a single match linked to another LINE id is unsure" do
      student!(%{display_name: "Amy", line_user_id: "U9"})
      assert {:unsure, [_]} = People.resolve_line_member("U1", "Amy")
    end

    test "a Student linked meanwhile cannot be claimed by another LINE id" do
      stale = student!(%{display_name: "Amy"})
      {:ok, _} = People.update_student(stale, %{line_user_id: "U9"})

      assert {:error, :already_linked} = People.claim_unlinked_student(stale, "U1")
      assert People.get_student(stale.id).line_user_id == "U9"
      assert {:unsure, [%{id: id}]} = People.resolve_line_member("U1", "Amy")
      assert id == stale.id
    end

    test "a Student cannot be claimed for a LINE id another Student holds" do
      winner = student!(%{display_name: "小美", line_user_id: "U1"})
      stale = student!(%{display_name: "Amy"})

      assert {:error, :line_user_id_taken} = People.claim_unlinked_student(stale, "U1")
      assert People.get_student(stale.id).line_user_id == nil
      assert {:known, %{id: id}} = People.resolve_line_member("U1", "Amy")
      assert id == winner.id
    end
  end

  defp student!(attrs) do
    {:ok, student} = People.create_student(attrs)
    student
  end
end
