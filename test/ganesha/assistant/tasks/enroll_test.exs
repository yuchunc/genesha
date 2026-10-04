defmodule Ganesha.Assistant.Tasks.EnrollTest do
  use Ganesha.DataCase, async: false

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Enroll

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
  end

  describe "describe/2" do
    test "shows the slot, the sessions, the package and what is owed", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c), c.ctx)

      for locale <- ["zh-TW", "en"] do
        description = Enroll.describe(parsed, locale)

        assert description.title =~ "Lulu"
        assert description.title =~ "基礎"
        assert Enum.any?(description.lines, &(&1 =~ "10/6" and &1 =~ "10/27" and &1 =~ "4"))
        assert Enum.any?(description.lines, &(&1 =~ "月課程" and &1 =~ Format.money(400)))
        assert [{_label, nil, owed}] = description.changes
        assert owed == Format.money(1600)
        assert description.web_path == "/enroll/#{c.slot.id}/2026/10"
      end
    end

    test "shows the custom amount as what is owed", c do
      {:ok, %{parsed: parsed}} = Enroll.propose(input(c, %{"custom_amount" => 1500}), c.ctx)

      assert [{_label, nil, owed}] = Enroll.describe(parsed, "zh-TW").changes
      assert owed == Format.money(1500)
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
  end
end
