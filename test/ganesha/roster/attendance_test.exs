defmodule Ganesha.Roster.AttendanceTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  defp august_setup do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 1600
      })

    %{slot: slot, sessions: sessions, student: student, purchase: purchase}
  end

  test "enroll/3 seats a student against a purchase" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()

    assert {:ok, att} = Roster.enroll(session, student, purchase)
    assert att.kind == "enrolled"
    assert att.state == "expected"
    assert att.purchase_id == purchase.id
  end

  test "a student cannot be seated twice on one session" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()
    {:ok, _} = Roster.enroll(session, student, purchase)

    assert {:error, cs} = Roster.enroll(session, student, purchase)
    assert "has already been taken" in errors_on(cs).session_id
  end

  test "add_drop_in/3 records kind from the package: drop_in" do
    %{sessions: [session | _]} = august_setup()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: jennifer.id, package_id: pkg.id, list_price: 450})

    assert {:ok, att} = Roster.add_drop_in(session, jennifer, purchase)
    assert att.kind == "drop_in"
  end

  test "add_drop_in/3 records kind from the package: trial" do
    %{sessions: [session | _]} = august_setup()
    {:ok, yufang} = People.create_student(%{display_name: "育芳"})

    {:ok, pkg} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 450})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: yufang.id, package_id: pkg.id, list_price: 450})

    assert {:ok, att} = Roster.add_drop_in(session, yufang, purchase)
    assert att.kind == "trial"
  end

  test "mark_no_show/1 and mark_expected/1 flip the state" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()
    {:ok, att} = Roster.enroll(session, student, purchase)

    assert {:ok, absent} = Roster.mark_no_show(att)
    assert absent.state == "no_show"

    assert {:ok, back} = Roster.mark_expected(absent)
    assert back.state == "expected"
  end

  test "list_for_session/1 preloads the student" do
    %{sessions: [session | _], student: student, purchase: purchase} = august_setup()
    {:ok, _} = Roster.enroll(session, student, purchase)

    assert [row] = Roster.list_for_session(session)
    assert row.student.display_name == "Lulu"
  end

  test "rejects an unknown kind" do
    %{sessions: [session | _], student: student} = august_setup()

    assert {:error, cs} =
             Roster.create_attendance(%{
               session_id: session.id,
               student_id: student.id,
               kind: "guest"
             })

    assert "is invalid" in errors_on(cs).kind
  end
end
