defmodule Ganesha.Assistant.Tasks.BookMakeupTest do
  use Ganesha.DataCase, async: false

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Studio}
  alias Ganesha.Assistant.Draft
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

  describe "with a makeup request" do
    setup c do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, request} =
        Assistant.create_draft(thread, %{
          kind: "makeup_request",
          student_id: c.student.id,
          parsed: %{"note" => "想補 10/8", "student_id" => c.student.id, "student_name" => "Lulu"}
        })

      input = %{
        "student_id" => c.student.id,
        "session_id" => c.session.id,
        "credit_id" => c.credit.id,
        "makeup_request_id" => request.id
      }

      {:ok, %{student_id: student_id, parsed: parsed}} =
        BookMakeup.propose(input, Map.put(c.ctx, :thread, thread))

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "book_makeup",
          student_id: student_id,
          parsed: parsed
        })

      %{thread: thread, request: request, input: input, draft: draft}
    end

    test "propose keeps the request's id", c do
      assert c.draft.parsed["makeup_request_id"] == c.request.id
    end

    test "propose rejects a request that is not a pending makeup request", c do
      {:ok, _} = Assistant.discard_draft(c.request)

      assert {:error, message} = BookMakeup.propose(c.input, c.ctx)
      assert message =~ "not a pending makeup request"
    end

    test "confirming books the makeup and settles the request with the Attendance", c do
      assert {:ok, %Draft{applied_record_id: attendance_id}} =
               Assistant.confirm_draft(c.draft, "line:Uteacher")

      assert [%{id: ^attendance_id, kind: "makeup"}] = Roster.list_for_session(c.session)

      request = Repo.reload!(c.request)
      assert request.state == "applied"
      assert request.applied_record_type == "Ganesha.Roster.Attendance"
      assert request.applied_record_id == attendance_id
    end

    test "a request handled meanwhile rolls the booking back", c do
      {:ok, _} = Assistant.confirm_draft(c.request, "line:Uteacher")

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(c.draft, "line:Uteacher")
      assert failed.failure_reason == "request_already_handled"

      assert Roster.list_for_session(c.session) == []
      assert Roster.get_credit(c.credit.id).consumed_by_attendance_id == nil
    end
  end

  test "summary names the student and the session" do
    parsed = %{
      "student_name" => "Lulu",
      "session_date" => "2026-10-08",
      "session_time" => "19:00–20:15",
      "session_label" => "基礎"
    }

    for locale <- ["zh-TW", "en"] do
      text = BookMakeup.summary(parsed, locale)
      for fact <- ["Lulu", "10/8", "19:00–20:15", "基礎"], do: assert(text =~ fact)
    end
  end

  defp slot_id(session) do
    session = Studio.get_session!(session.id)
    session.slot_id
  end
end
