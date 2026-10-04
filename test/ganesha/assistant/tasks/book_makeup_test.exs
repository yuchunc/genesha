defmodule Ganesha.Assistant.Tasks.BookMakeupTest do
  use Ganesha.DataCase, async: false

  alias Ganesha.{Catalog, Enrolling, People, Roster, Studio}
  alias Ganesha.Assistant.Tasks.BookMakeup

  setup do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 4,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, enroll_session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-01], style: "Hatha"})

    {:ok, makeup_session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-08], style: "Hatha"})

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: student,
        slot: slot,
        package: monthly,
        sessions: [enroll_session],
        custom_amount: nil,
        note: nil
      })

    [credit] = Roster.available_credits(student.id, makeup_session.date)

    %{
      ctx: %{locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      session: makeup_session,
      credit: credit
    }
  end

  test "books a makeup and spends the credit", c do
    input = %{
      "student_id" => c.student.id,
      "session_id" => c.session.id,
      "credit_id" => c.credit.id
    }

    assert {:ok, %{parsed: parsed}} = BookMakeup.propose(input, c.ctx)
    assert {:ok, {_, attendance_id}} = BookMakeup.apply(parsed, "line:teacher")

    assert [%{id: ^attendance_id, kind: "makeup"}] = Roster.list_for_session(c.session)
    assert Roster.get_credit(c.credit.id).consumed_by_attendance_id == attendance_id
  end

  test "apply fails if the credit was spent after propose", c do
    {:ok, other} =
      Studio.create_session(%{slot_id: slot_id(c.session), date: ~D[2026-10-15], style: "Hatha"})

    input = %{
      "student_id" => c.student.id,
      "session_id" => c.session.id,
      "credit_id" => c.credit.id
    }

    {:ok, %{parsed: parsed}} = BookMakeup.propose(input, c.ctx)
    {:ok, _} = Roster.book_makeup(other, c.student, c.credit)

    assert {:error, :credit_already_consumed} = BookMakeup.apply(parsed, "line:teacher")
    assert Roster.list_for_session(c.session) == []
  end

  defp slot_id(session) do
    session = Studio.get_session!(session.id)
    session.slot_id
  end
end
