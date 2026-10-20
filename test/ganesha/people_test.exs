defmodule Ganesha.PeopleTest do
  use Ganesha.DataCase
  alias Ganesha.{Assistant, Catalog, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Draft
  alias Ganesha.People.{LineMember, Student, StudentAlias}
  alias Ganesha.Roster.Credit

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

    test "a lost race inside an outer transaction re-reads the member instead of raising" do
      # Each case gets the candidates matched before a concurrent event wrote,
      # so its first write fails; the outer transaction must stay usable.
      winner = student!(%{display_name: "小美", line_user_id: "U1"})
      unlinked = student!(%{display_name: "Amy"})
      linked_meanwhile = student!(%{display_name: "Bo"})
      {:ok, _} = People.update_student(linked_meanwhile, %{line_user_id: "U9"})
      Repo.insert!(%LineMember{line_user_id: "U3", display_name: "Cy", state: "unsure"})

      assert {:ok, results} =
               Repo.transaction(fn ->
                 [
                   People.resolve_matches("U1", "小美", []),
                   People.resolve_matches("U1", "Amy", [unlinked]),
                   People.resolve_matches("U2", "Bo", [linked_meanwhile]),
                   People.resolve_matches("U3", "Cy", [unlinked, linked_meanwhile])
                 ]
               end)

      winner_id = winner.id
      bo_id = linked_meanwhile.id

      assert [
               {:known, %{id: ^winner_id}},
               {:known, %{id: ^winner_id}},
               {:unsure, [%{id: ^bo_id}]},
               :pending
             ] = results

      assert People.get_student(unlinked.id).line_user_id == nil
      assert %LineMember{state: "unsure"} = People.get_line_member("U2")
    end
  end

  describe "member taps" do
    test "not a student from created deletes a student without records" do
      {:created, s} = People.resolve_line_member("U1", "小美")
      {:ok, _} = People.add_alias(s, "美美")
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      draft =
        Repo.insert!(%Draft{
          thread_id: thread.id,
          kind: "record_payment",
          parsed: %{},
          student_id: s.id
        })

      assert {:ok, :marked} = People.member_not_student("U1", "小美", "created", s.id)
      assert People.get_student(s.id) == nil
      assert Repo.aggregate(StudentAlias, :count) == 0
      assert Repo.reload!(draft).student_id == nil

      assert %LineMember{state: "not_student", display_name: "小美"} =
               People.get_line_member("U1")
    end

    test "not a student from created keeps a student who has records" do
      {:created, s} = People.resolve_line_member("U1", "小美")
      purchase_for!(s)

      assert {:ok, {:kept, %{id: id, line_user_id: nil}}} =
               People.member_not_student("U1", "小美", "created", s.id)

      assert id == s.id
      assert %LineMember{state: "not_student"} = People.get_line_member("U1")
    end

    test "an attendance or a credit alone also keeps the student" do
      {:created, attended} = People.resolve_line_member("U1", "小美")
      {:created, credited} = People.resolve_line_member("U2", "小華")
      session = session!()

      {:ok, _} =
        Roster.create_attendance(%{
          session_id: session.id,
          student_id: attended.id,
          kind: "drop_in"
        })

      Repo.insert!(
        Credit.changeset(%Credit{}, %{student_id: credited.id, source: "cancellation"})
      )

      assert {:ok, {:kept, _}} = People.member_not_student("U1", "小美", "created", attended.id)
      assert {:ok, {:kept, _}} = People.member_not_student("U2", "小華", "created", credited.id)
      assert People.get_student(attended.id).line_user_id == nil
      assert People.get_student(credited.id).line_user_id == nil
    end

    test "not a student from linked unlinks and keeps the student" do
      s = student!(%{display_name: "Amy"})
      {:linked, _} = People.resolve_line_member("U1", "Amy")

      assert {:ok, :marked} = People.member_not_student("U1", "Amy", "linked", s.id)
      assert %Student{line_user_id: nil} = People.get_student(s.id)
      assert %LineMember{state: "not_student", display_name: "Amy"} = People.get_line_member("U1")
    end

    test "not a student from unsure answers the open question" do
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})

      assert {:ok, :marked} = People.member_not_student("U1", "Amy", "unsure", nil)
      assert %LineMember{state: "not_student"} = People.get_line_member("U1")
      assert :not_student = People.resolve_line_member("U1", "Amy")
    end

    test "wrong link unlinks, opens a question and returns fresh candidates" do
      a = student!(%{display_name: "Amy"})
      {:linked, _} = People.resolve_line_member("U1", "Amy")
      b = student!(%{display_name: "amy"})

      assert {:ok, candidates} = People.member_wrong_link("U1", "Amy", a.id)
      assert Enum.map(candidates, & &1.id) == [a.id, b.id]
      assert People.get_student(a.id).line_user_id == nil
      assert %LineMember{state: "unsure", display_name: "Amy"} = People.get_line_member("U1")
      assert :pending = People.resolve_line_member("U1", "Amy")
    end

    test "pick links the candidate and closes the question" do
      s = student!(%{display_name: "Amy"})
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})

      assert {:ok, %Student{id: id, line_user_id: "U1"}} = People.member_pick("U1", s.id)
      assert id == s.id
      assert People.get_line_member("U1") == nil
    end

    test "pick refuses an inactive or already linked candidate and changes nothing" do
      inactive = student!(%{display_name: "Amy", active: false})
      linked = student!(%{display_name: "Amy", line_user_id: "U9"})
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})

      assert {:error, :already_handled} = People.member_pick("U1", inactive.id)
      assert {:error, :already_handled} = People.member_pick("U1", linked.id)
      assert {:error, :already_handled} = People.member_pick("U1", -1)
      assert People.get_student(inactive.id).line_user_id == nil
      assert People.get_student(linked.id).line_user_id == "U9"
      assert %LineMember{state: "unsure"} = People.get_line_member("U1")
    end

    test "new creates a linked student named after LINE and closes the question" do
      student!(%{display_name: "Amy"})
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})

      assert {:ok, %Student{display_name: "Amy", line_user_id: "U1"} = s} =
               People.member_new("U1", "Amy")

      assert People.find_by_line_user_id("U1").id == s.id
      assert People.get_line_member("U1") == nil
    end

    test "a tap on a member already handled changes nothing" do
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})
      {:ok, _} = People.member_new("U1", "Amy")
      assert {:error, :already_handled} = People.member_pick("U1", 1)
      assert {:error, :already_handled} = People.member_new("U1", "Amy")
    end

    test "a tap on a link that no longer holds changes nothing" do
      s = student!(%{display_name: "Amy"})
      {:linked, _} = People.resolve_line_member("U1", "Amy")
      {:ok, :marked} = People.member_not_student("U1", "Amy", "linked", s.id)

      assert {:error, :already_handled} = People.member_wrong_link("U1", "Amy", s.id)
      assert {:error, :already_handled} = People.member_not_student("U1", "Amy", "linked", s.id)
      assert {:error, :already_handled} = People.member_not_student("U1", "Amy", "created", s.id)
      assert {:error, :already_handled} = People.member_not_student("U1", "Amy", "unsure", nil)
      assert People.get_student(s.id).line_user_id == nil
      assert %LineMember{state: "not_student"} = People.get_line_member("U1")
    end

    test "the not-student answer from unsure is refused once the question is closed" do
      s = student!(%{display_name: "Amy"})
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})
      {:ok, _} = People.member_pick("U1", s.id)

      assert {:error, :already_handled} = People.member_not_student("U1", "Amy", "unsure", nil)
      assert People.get_line_member("U1") == nil
      assert People.get_student(s.id).line_user_id == "U1"
    end

    test "a stale not-student tap from unsure is refused once enrollment links the member" do
      a = student!(%{display_name: "Amy"})
      student!(%{display_name: "amy"})
      {:unsure, _} = People.resolve_line_member("U1", "Amy")

      # The sign-up / enroll path links through link_line_user_id/2.
      {:ok, _} = People.link_line_user_id(a, "U1")

      assert People.get_line_member("U1") == nil
      assert {:error, :already_handled} = People.member_not_student("U1", "Amy", "unsure", nil)
      assert People.get_student(a.id).line_user_id == "U1"
      assert People.get_line_member("U1") == nil
    end

    test "every way a Student gets a LINE id closes an open question about it" do
      for id <- ~w(U1 U2 U3) do
        Repo.insert!(%LineMember{line_user_id: id, display_name: "Amy", state: "unsure"})
      end

      {:ok, _} = People.create_student(%{display_name: "Amy", line_user_id: "U1"})
      {:ok, _} = People.claim_unlinked_student(student!(%{display_name: "Bo"}), "U2")
      {:ok, _} = People.update_student(student!(%{display_name: "Cy"}), %{line_user_id: "U3"})

      assert Repo.aggregate(LineMember, :count) == 0
    end

    test "linking a Student leaves a not-student answer alone" do
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "not_student"})
      student!(%{display_name: "Amy", line_user_id: "U1"})

      assert %LineMember{state: "not_student"} = People.get_line_member("U1")
    end

    test "the not-student answer from unsure is refused while a Student holds the LINE id" do
      s = student!(%{display_name: "Amy", line_user_id: "U1"})
      Repo.insert!(%LineMember{line_user_id: "U1", display_name: "Amy", state: "unsure"})

      assert {:error, :already_handled} = People.member_not_student("U1", "Amy", "unsure", nil)
      assert %LineMember{state: "unsure"} = People.get_line_member("U1")
      assert People.get_student(s.id).line_user_id == "U1"
    end
  end

  defp purchase_for!(student) do
    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 400})

    purchase
  end

  defp session! do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 3,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

    session
  end

  defp student!(attrs) do
    {:ok, student} = People.create_student(attrs)
    student
  end
end
