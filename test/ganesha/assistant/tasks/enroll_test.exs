defmodule Ganesha.Assistant.Tasks.EnrollTest do
  use Ganesha.DataCase, async: false

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Draft
  alias Ganesha.Assistant.Tasks.Enroll
  alias Ganesha.People.Student
  alias Ganesha.Sales.Purchase

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 2,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    # October 2026 has four Tuesdays: 6, 13, 20, 27.
    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-10-01])

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, drop_in} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 500})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      slot: slot,
      sessions: sessions,
      monthly: monthly,
      drop_in: drop_in
    }
  end

  defp input(c, extra \\ %{}) do
    Map.merge(
      %{
        "student_id" => c.student.id,
        "slot_id" => c.slot.id,
        "month" => "2026-10",
        "package_id" => c.monthly.id
      },
      extra
    )
  end

  # An unlinked sign-up request, as a Student chat proposes it.
  defp signup_request(line_user_id) do
    {:ok, chat} = Assistant.get_or_create_thread("user", line_user_id)

    {:ok, request} =
      Assistant.create_draft(chat, %{
        kind: "signup_request",
        parsed: %{
          "note" => "想報名週二晚上",
          "student_id" => nil,
          "student_name" => nil,
          "line_user_id" => line_user_id,
          "line_name" => "小美",
          "new" => true
        }
      })

    request
  end

  defp newcomer_input(c, request) do
    c
    |> input(%{"signup_request_id" => request.id, "new_student_name" => " 小美 "})
    |> Map.delete("student_id")
  end

  defp enroll_draft(c, input) do
    {:ok, %{student_id: student_id, parsed: parsed}} = Enroll.propose(input, c.ctx)

    {:ok, draft} =
      Assistant.create_draft(c.ctx.thread, %{
        kind: "enroll",
        student_id: student_id,
        parsed: parsed
      })

    draft
  end

  describe "propose/2" do
    test "takes every scheduled session of the slot in the month and prices them", c do
      {:ok, _} = Studio.cancel_session(Enum.at(c.sessions, 1), "颱風")

      assert {:ok, %{student_id: student_id, parsed: parsed}} = Enroll.propose(input(c), c.ctx)

      assert student_id == c.student.id
      assert parsed["session_ids"] == Enum.map([0, 2, 3], &Enum.at(c.sessions, &1).id)
      assert parsed["session_dates"] == ["2026-10-06", "2026-10-20", "2026-10-27"]
      assert parsed["price"] == 1200
      assert parsed["month"] == "2026-10"
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "takes only the sessions the teacher named", c do
      [first, _, third, _] = c.sessions

      assert {:ok, %{parsed: parsed}} =
               Enroll.propose(input(c, %{"session_ids" => [third.id, first.id]}), c.ctx)

      assert parsed["session_ids"] == [first.id, third.id]
      assert parsed["price"] == 800
    end

    test "rejects a session that is not the slot's in that month", c do
      {:ok, other} =
        Studio.create_session(%{slot_id: c.slot.id, date: ~D[2026-11-03], style: "Hatha"})

      assert {:error, message} =
               Enroll.propose(input(c, %{"session_ids" => [other.id]}), c.ctx)

      assert message =~ "#{other.id}"
    end

    test "rejects a package that is not monthly", c do
      assert {:error, _} = Enroll.propose(input(c, %{"package_id" => c.drop_in.id}), c.ctx)
    end

    test "rejects a package closed to this student", c do
      {:ok, _} = Catalog.update_package(c.monthly, %{active: false})
      assert {:error, _} = Enroll.propose(input(c), c.ctx)
    end

    test "rejects an inactive student", c do
      {:ok, _} = People.update_student(c.student, %{active: false})
      assert {:error, _} = Enroll.propose(input(c), c.ctx)
    end

    test "rejects a month with no scheduled sessions", c do
      assert {:error, _} = Enroll.propose(input(c, %{"month" => "2026-12"}), c.ctx)
    end

    test "rejects a malformed month", c do
      assert {:error, _} = Enroll.propose(input(c, %{"month" => "October"}), c.ctx)
    end

    test "names the dates the student is already booked on", c do
      [first | _] = c.sessions
      {:ok, _} = Enrolling.add_one_off(first, c.student, c.drop_in, [])

      assert {:error, message} = Enroll.propose(input(c), c.ctx)
      assert message =~ "2026-10-06"
    end

    test "rejects a negative custom amount", c do
      assert {:error, _} = Enroll.propose(input(c, %{"custom_amount" => -1}), c.ctx)
    end
  end

  describe "propose/2 with a sign-up request" do
    test "a newcomer becomes a new student with the request's LINE id", c do
      request = signup_request("Unewcomer")

      assert {:ok, %{student_id: nil, parsed: parsed}} =
               Enroll.propose(newcomer_input(c, request), c.ctx)

      assert parsed["signup_request_id"] == request.id
      assert parsed["new_student"] == %{"display_name" => "小美", "line_user_id" => "Unewcomer"}
      assert parsed["student_name"] == "小美"
      assert parsed["link_line_user_id"] == nil
      assert length(parsed["session_ids"]) == 4
    end

    test "a snapshot student gets the request's LINE id linked", c do
      request = signup_request("Ululu")

      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               Enroll.propose(input(c, %{"signup_request_id" => request.id}), c.ctx)

      assert student_id == c.student.id
      assert parsed["link_line_user_id"] == "Ululu"
      assert parsed["new_student"] == nil
    end

    test "without student_id, the student linked to the request's LINE id is enrolled", c do
      {:ok, _} = People.update_student(c.student, %{line_user_id: "Ululu"})
      request = signup_request("Ululu")

      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               Enroll.propose(newcomer_input(c, request), c.ctx)

      assert student_id == c.student.id
      assert parsed["new_student"] == nil
      assert parsed["link_line_user_id"] == nil
    end

    test "links nothing when another student already holds the request's LINE id", c do
      {:ok, _} = People.create_student(%{display_name: "媽媽", line_user_id: "Umom"})
      request = signup_request("Umom")

      assert {:ok, %{parsed: parsed}} =
               Enroll.propose(input(c, %{"signup_request_id" => request.id}), c.ctx)

      assert parsed["link_line_user_id"] == nil
    end

    test "rejects a student linked to a different LINE id than the request's", c do
      {:ok, _} = People.update_student(c.student, %{line_user_id: "Uother"})
      request = signup_request("Unewcomer")

      assert {:error, message} =
               Enroll.propose(input(c, %{"signup_request_id" => request.id}), c.ctx)

      assert message =~ "different LINE account"
    end

    test "new_student_name needs a sign-up request, and some student is always needed", c do
      no_student = Map.delete(input(c), "student_id")

      assert {:error, message} =
               Enroll.propose(Map.put(no_student, "new_student_name", "小美"), c.ctx)

      assert message =~ "signup_request_id"

      assert {:error, message} = Enroll.propose(no_student, c.ctx)
      assert message =~ "student_id"

      request = signup_request("Unewcomer")

      assert {:error, message} =
               Enroll.propose(Map.put(no_student, "signup_request_id", request.id), c.ctx)

      assert message =~ "new_student_name"
    end

    test "rejects a request that is not a pending sign-up request", c do
      request = signup_request("Unewcomer")
      {:ok, _} = Assistant.discard_draft(request)

      assert {:error, message} = Enroll.propose(newcomer_input(c, request), c.ctx)
      assert message =~ "not a pending sign-up request"

      {:ok, makeup} =
        Assistant.create_draft(c.ctx.thread, %{kind: "makeup_request", parsed: %{"note" => "x"}})

      assert {:error, _} =
               Enroll.propose(input(c, %{"signup_request_id" => makeup.id}), c.ctx)
    end

    test "a new student only needs the package to be open to anyone", c do
      {:ok, _} = Catalog.update_package(c.monthly, %{active: false})
      request = signup_request("Unewcomer")

      assert {:error, message} = Enroll.propose(newcomer_input(c, request), c.ctx)
      assert message =~ "closed to new students"
    end
  end

  describe "apply/2" do
    test "creates the purchase, books every session and mints the package credits", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)

      assert {:ok, {"Ganesha.Sales.Purchase", purchase_id}} = Enroll.apply(parsed, "line:teacher")

      purchase = Sales.get_purchase!(purchase_id)
      assert purchase.list_price == 1600
      assert purchase.slot_id == c.slot.id

      for session <- c.sessions do
        assert [%{kind: "enrolled", purchase_id: ^purchase_id}] = Roster.list_for_session(session)
      end

      assert [_credit] = Roster.available_credits(c.student.id, ~D[2026-10-27])
    end

    test "a custom amount is what the purchase owes", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c, %{"custom_amount" => 1500}), c.ctx)
      {:ok, {_, purchase_id}} = Enroll.apply(parsed, "line:teacher")

      assert Sales.payable(Sales.get_purchase!(purchase_id)) == 1500
    end

    test "fails if a session was cancelled after the Draft was made", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Studio.cancel_session(List.last(c.sessions), "颱風")

      assert {:error, :session_cancelled} = Enroll.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "fails if the package was closed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Catalog.update_package(c.monthly, %{active: false})

      assert {:error, :package_unavailable} = Enroll.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "fails if the package price changed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Catalog.update_package(c.monthly, %{price_per_class: 450})

      assert {:error, :price_changed} = Enroll.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "a student booked in the meantime fails the confirm and writes nothing", c do
      {:ok, %{student_id: student_id, parsed: parsed}} = Enroll.propose(input(c), c.ctx)
      {:ok, _} = Enrolling.add_one_off(List.last(c.sessions), c.student, c.drop_in, [])

      {:ok, draft} =
        Assistant.create_draft(c.ctx.thread, %{
          kind: "enroll",
          student_id: student_id,
          parsed: parsed
        })

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(draft, "line:teacher")
      assert failed.state == "failed"
      assert [_one_off] = Sales.list_purchases_for_student(c.student.id)
      assert Roster.list_for_session(hd(c.sessions)) == []
    end

    test "a newcomer's request adds the student, enrolls them and settles the request", c do
      request = signup_request("Unewcomer")
      draft = enroll_draft(c, newcomer_input(c, request))

      assert {:ok, %Draft{applied_record_id: purchase_id}} =
               Assistant.confirm_draft(draft, "line:Uteacher")

      student = People.find_by_line_user_id("Unewcomer")
      assert student.display_name == "小美"
      assert Sales.get_purchase!(purchase_id).student_id == student.id

      for session <- c.sessions do
        assert [%{student_id: student_id}] = Roster.list_for_session(session)
        assert student_id == student.id
      end

      request = Repo.reload!(request)
      assert request.state == "applied"
      assert request.applied_record_type == "Ganesha.Sales.Purchase"
      assert request.applied_record_id == purchase_id
    end

    test "a snapshot student's request links the LINE id and settles the request", c do
      request = signup_request("Ululu")
      draft = enroll_draft(c, input(c, %{"signup_request_id" => request.id}))

      assert {:ok, %Draft{applied_record_id: purchase_id}} =
               Assistant.confirm_draft(draft, "line:Uteacher")

      assert People.get_student(c.student.id).line_user_id == "Ululu"
      assert Repo.reload!(request).applied_record_id == purchase_id
    end

    test "a request handled meanwhile fails the confirm and books nothing", c do
      request = signup_request("Unewcomer")
      draft = enroll_draft(c, newcomer_input(c, request))
      {:ok, _} = Assistant.confirm_draft(request, "line:Uteacher")

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(draft, "line:Uteacher")
      assert failed.failure_reason == "request_already_handled"

      refute People.find_by_line_user_id("Unewcomer")
      assert Repo.aggregate(Purchase, :count) == 0
      assert Roster.list_for_session(hd(c.sessions)) == []
    end

    test "a newcomer whose LINE id got linked meanwhile is not added twice", c do
      request = signup_request("Unewcomer")
      draft = enroll_draft(c, newcomer_input(c, request))
      {:ok, _} = People.update_student(c.student, %{line_user_id: "Unewcomer"})

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(draft, "line:Uteacher")
      assert failed.failure_reason == "line_user_id_taken"

      assert Repo.aggregate(Student, :count) == 1
      assert Repo.aggregate(Purchase, :count) == 0
      assert Repo.reload!(request).state == "pending"
    end
  end

  describe "summary/2" do
    test "summary names the student, month, class, count and what is owed" do
      parsed = %{
        "student_name" => "Lulu",
        "month" => "2026-10",
        "slot_weekday" => 2,
        "slot_time" => "19:00–20:15",
        "slot_label" => "基礎",
        "session_ids" => [1, 2, 3, 4],
        "custom_amount" => nil,
        "price" => 1600
      }

      for locale <- ["zh-TW", "en"] do
        text = Enroll.summary(parsed, locale)
        for fact <- ["Lulu", "基礎", "19:00–20:15", "4", "NT$1,600"], do: assert(text =~ fact)
      end

      assert Enroll.summary(parsed, "zh-TW") =~ "10月"
      assert Enroll.summary(parsed, "en") =~ "October"
      assert Enroll.summary(%{parsed | "custom_amount" => 1500}, "zh-TW") =~ "NT$1,500"
    end

    test "a new student's summary says the student is added first" do
      parsed = %{
        "student_name" => "小美",
        "new_student" => %{"display_name" => "小美", "line_user_id" => "Unewcomer"},
        "month" => "2026-10",
        "slot_weekday" => 2,
        "slot_time" => "19:00–20:15",
        "slot_label" => "基礎",
        "session_ids" => [1, 2, 3, 4],
        "custom_amount" => nil,
        "price" => 1600
      }

      assert String.starts_with?(Enroll.summary(parsed, "zh-TW"), "新增學生 小美 並")
      assert String.starts_with?(Enroll.summary(parsed, "en"), "Add new student 小美 and ")
    end
  end
end
