defmodule Ganesha.RosterTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}

  defp slot_with_sessions(weekday, label) do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: weekday,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: label
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {slot, sessions}
  end

  defp package(kind, price) do
    Catalog.create_package(%{
      name: "#{kind}-#{System.unique_integer([:positive])}",
      kind: kind,
      price_per_class: price,
      included_makeups: if(kind == "monthly", do: 1, else: 0)
    })
  end

  test "cancelling a makeup session grants a new cancellation credit" do
    {monday, mondays} = slot_with_sessions(1, "週一")
    {_friday, fridays} = slot_with_sessions(5, "週五")
    {:ok, student} = People.create_student(%{display_name: "蘭子"})
    {:ok, monthly} = package("monthly", 400)

    {:ok, %{credits: [credit]}} =
      Enrolling.enroll_month(%{
        student: student,
        slot: monday,
        package: monthly,
        sessions: mondays,
        custom_amount: nil,
        note: nil
      })

    makeup_session = hd(fridays)
    {:ok, makeup} = Roster.book_makeup(makeup_session, student, credit)
    {:ok, cancelled} = Studio.cancel_session(makeup_session, "颱風假")

    assert {:ok, [replacement]} = Roster.issue_cancellation_credits(cancelled)
    assert replacement.student_id == student.id
    assert replacement.source == "cancellation"
    assert replacement.origin_session_id == cancelled.id
    assert replacement.expires_on == nil
    assert replacement.consumed_by_attendance_id == nil
    assert Roster.available_credits(student.id, ~D[2026-12-01]) == [replacement]
    assert Roster.get_attendance!(makeup.id).kind == "makeup"
  end

  test "cancelling a one-off session grants credits to drop-in and trial attendees" do
    {_slot, [session | _]} = slot_with_sessions(1, "週一")
    {:ok, drop_in} = package("drop_in", 450)
    {:ok, trial} = package("trial", 300)
    {:ok, drop_student} = People.create_student(%{display_name: "Jennifer"})
    {:ok, trial_student} = People.create_student(%{display_name: "Alice"})

    {:ok, drop_purchase} =
      Sales.create_purchase(%{
        student_id: drop_student.id,
        package_id: drop_in.id,
        list_price: 450
      })

    {:ok, trial_purchase} =
      Sales.create_purchase(%{
        student_id: trial_student.id,
        package_id: trial.id,
        list_price: 300
      })

    {:ok, _drop_attendance} = Roster.add_drop_in(session, drop_student, drop_purchase)
    {:ok, _trial_attendance} = Roster.add_drop_in(session, trial_student, trial_purchase)
    {:ok, cancelled} = Studio.cancel_session(session, "颱風假")

    assert {:ok, credits} = Roster.issue_cancellation_credits(cancelled)

    assert Enum.sort(Enum.map(credits, & &1.student_id)) ==
             Enum.sort([drop_student.id, trial_student.id])

    assert Enum.all?(credits, &(&1.source == "cancellation"))
    assert Enum.all?(credits, &(&1.origin_session_id == cancelled.id))
    assert Enum.all?(credits, &is_nil(&1.expires_on))
  end

  describe "count_by_session/1" do
    test "counts attendance rows per session, including no-shows" do
      {monday, [session | _]} = slot_with_sessions(1, "週一")
      {:ok, student_a} = People.create_student(%{display_name: "小美"})
      {:ok, student_b} = People.create_student(%{display_name: "小華"})
      {:ok, monthly} = package("monthly", 400)

      {:ok, purchase_a} =
        Sales.create_purchase(%{
          student_id: student_a.id,
          package_id: monthly.id,
          slot_id: monday.id,
          list_price: 2000
        })

      {:ok, purchase_b} =
        Sales.create_purchase(%{
          student_id: student_b.id,
          package_id: monthly.id,
          slot_id: monday.id,
          list_price: 2000
        })

      {:ok, _} = Roster.enroll(session, student_a, purchase_a)
      {:ok, attendance_b} = Roster.enroll(session, student_b, purchase_b)
      {:ok, _} = Roster.mark_no_show(attendance_b)

      assert Roster.count_by_session([session.id]) == %{session.id => 2}
    end

    test "returns an empty map for an empty list without querying" do
      assert Roster.count_by_session([]) == %{}
    end
  end
end
