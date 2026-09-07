defmodule Ganesha.EnrollingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}

  defp context do
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

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    %{slot: slot, sessions: sessions, student: student, monthly: monthly}
  end

  test "enroll_month/1 creates the purchase, seats every session, and mints the credit" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()

    assert {:ok, result} =
             Enrolling.enroll_month(%{
               student: student,
               slot: slot,
               package: monthly,
               sessions: sessions,
               custom_amount: nil,
               note: nil
             })

    # Five Mondays at 400 each.
    assert result.purchase.list_price == 2000
    assert is_nil(result.purchase.custom_amount)
    assert result.purchase.slot_id == slot.id
    assert length(result.attendances) == 5
    assert Enum.all?(result.attendances, &(&1.kind == "enrolled"))
    assert length(result.credits) == 1
    assert hd(result.credits).expires_on == ~D[2026-08-31]
  end

  test "enroll_month/1 prices only the sessions actually bought" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()
    two = Enum.take(sessions, 2)

    assert {:ok, result} =
             Enrolling.enroll_month(%{
               student: student,
               slot: slot,
               package: monthly,
               sessions: two,
               custom_amount: nil,
               note: nil
             })

    # 彩華's two classes at the package rate.
    assert result.purchase.list_price == 800
    assert length(result.attendances) == 2
  end

  test "enroll_month/1 honours a custom amount and a note" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()

    assert {:ok, result} =
             Enrolling.enroll_month(%{
               student: student,
               slot: slot,
               package: monthly,
               sessions: sessions,
               custom_amount: 0,
               note: "按摩器代購"
             })

    assert result.purchase.list_price == 2000
    assert Sales.payable(result.purchase) == 0
    assert result.purchase.note == "按摩器代購"
  end

  test "enroll_month/1 refuses an empty session list" do
    %{slot: slot, student: student, monthly: monthly} = context()

    assert {:error, :no_sessions} =
             Enrolling.enroll_month(%{
               student: student,
               slot: slot,
               package: monthly,
               sessions: [],
               custom_amount: nil,
               note: nil
             })
  end

  test "enroll_month/1 rolls back completely if a session is already taken" do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = context()

    {:ok, first} =
      Enrolling.enroll_month(%{
        student: student,
        slot: slot,
        package: monthly,
        sessions: Enum.take(sessions, 1),
        custom_amount: nil,
        note: nil
      })

    purchases_before = length(Sales.list_purchases_for_student(student.id))

    # Overlaps the session already seated by `first`.
    assert {:error, _} =
             Enrolling.enroll_month(%{
               student: student,
               slot: slot,
               package: monthly,
               sessions: sessions,
               custom_amount: nil,
               note: nil
             })

    assert length(Sales.list_purchases_for_student(student.id)) == purchases_before,
           "a failed enrollment must not leave an orphan purchase behind"

    assert length(Roster.list_for_student(student.id)) == 1
    assert first.purchase.id == hd(Sales.list_purchases_for_student(student.id)).id
  end

  test "add_one_off/4 creates a drop-in purchase and seats one session" do
    %{sessions: sessions} = context()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    assert {:ok, result} = Enrolling.add_one_off(hd(sessions), jennifer, drop_in, [])

    assert result.purchase.list_price == 450
    assert is_nil(result.purchase.slot_id), "a drop-in is not tied to a slot"
    assert result.attendance.kind == "drop_in"
  end

  test "add_one_off/4 supports a trial and a custom amount" do
    %{sessions: sessions} = context()
    {:ok, yufang} = People.create_student(%{display_name: "育芳"})

    {:ok, trial} =
      Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 450})

    assert {:ok, result} =
             Enrolling.add_one_off(hd(sessions), yufang, trial,
               custom_amount: 400,
               note: "朋友介紹"
             )

    assert Sales.payable(result.purchase) == 400
    assert result.attendance.kind == "trial"
  end

  test "add_one_off/4 mints no credit" do
    %{sessions: sessions} = context()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, _} = Enrolling.add_one_off(hd(sessions), jennifer, drop_in, [])

    assert Roster.available_credits(jennifer.id, ~D[2026-08-03]) == []
  end
end
