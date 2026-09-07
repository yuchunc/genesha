defmodule Ganesha.ReportingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Reporting, Roster, Sales, Studio}

  defp monthly_package do
    Catalog.create_package(%{
      name: "月課程-#{System.unique_integer([:positive])}",
      kind: "monthly",
      price_per_class: 400,
      included_makeups: 1
    })
  end

  # Creates an enrolled August purchase and optionally pays it.
  defp august_sale(paid_amount, opts \\ []) do
    confirm? = Keyword.get(opts, :confirm, true)

    start_time = Time.add(~T[09:30:00], System.unique_integer([:positive]), :second)

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: start_time,
        end_time: Time.add(start_time, 75, :minute),
        default_style: "基礎",
        label: "slot-#{System.unique_integer([:positive])}"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, student} =
      People.create_student(%{display_name: "S#{System.unique_integer([:positive])}"})

    {:ok, pkg} = monthly_package()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 1600
      })

    for session <- sessions, do: {:ok, _} = Roster.enroll(session, student, purchase)

    if paid_amount > 0 do
      {:ok, payment} =
        Sales.record_payment(%{
          purchase_id: purchase.id,
          amount: paid_amount,
          method: "line_pay",
          paid_on: ~D[2026-08-05]
        })

      if confirm?, do: {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    end

    %{student: student, purchase: purchase}
  end

  test "outstanding is payable minus confirmed payments" do
    %{student: student} = august_sale(1200)
    assert Reporting.outstanding_for_student(student.id) == 400
  end

  test "an unconfirmed claim does not reduce what is outstanding" do
    %{student: student} = august_sale(1600, confirm: false)

    assert Reporting.outstanding_for_student(student.id) == 1600,
           "money she has not verified must not count as received"
  end

  test "an override changes what is owed" do
    %{student: student, purchase: purchase} = august_sale(0)
    {:ok, _} = Sales.update_purchase(purchase, %{custom_amount: 0, note: "按摩器代購"})

    assert Reporting.outstanding_for_student(student.id) == 0
  end

  test "outstanding_by_student/0 omits settled students and sorts by amount" do
    %{student: owes_more} = august_sale(0)
    %{student: owes_less} = august_sale(1200)
    %{student: settled} = august_sale(1600)

    rows = Reporting.outstanding_by_student()
    ids = Enum.map(rows, & &1.student.id)

    refute settled.id in ids
    assert ids == [owes_more.id, owes_less.id]
    assert hd(rows).outstanding == 1600
  end

  test "revenue_for_month/1 counts only confirmed payments inside the month" do
    august_sale(1200)
    august_sale(1600, confirm: false)

    assert Reporting.revenue_for_month(~D[2026-08-01]) == 1200
    assert Reporting.revenue_for_month(~D[2026-09-01]) == 0
  end

  describe "revenue_by_method_for_month/1" do
    test "groups confirmed revenue by method, ordered, zero-filled" do
      {:ok, student} = People.create_student(%{display_name: "彩華"})
      {:ok, pkg} = monthly_package()

      {:ok, cash_purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, cash_payment} =
        Sales.record_payment(%{
          purchase_id: cash_purchase.id,
          amount: 400,
          method: "cash",
          paid_on: ~D[2026-08-05]
        })

      {:ok, _} = Sales.confirm_payment(cash_payment, "teacher@example.com")

      {:ok, line_pay_purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 800})

      {:ok, line_pay_payment} =
        Sales.record_payment(%{
          purchase_id: line_pay_purchase.id,
          amount: 800,
          method: "line_pay",
          paid_on: ~D[2026-08-10]
        })

      {:ok, _} = Sales.confirm_payment(line_pay_payment, "teacher@example.com")

      assert Reporting.revenue_by_method_for_month(~D[2026-08-01]) == [
               {"line_pay", 800},
               {"line_bank", 0},
               {"cash", 400},
               {"other", 0}
             ]
    end

    test "leaves out unconfirmed claims and other months" do
      august_sale(1200, confirm: false)

      assert Reporting.revenue_by_method_for_month(~D[2026-08-01]) == [
               {"line_pay", 0},
               {"line_bank", 0},
               {"cash", 0},
               {"other", 0}
             ]
    end
  end

  test "tax_threshold_status/1 stays quiet at low revenue" do
    august_sale(1200)
    status = Reporting.tax_threshold_status(~D[2026-08-01])

    assert status.threshold == 50_000
    assert status.revenue == 1200
    refute status.warn?
  end

  test "tax_threshold_status/1 warns as the month approaches NT$50,000" do
    for _ <- 1..29, do: august_sale(1600)

    status = Reporting.tax_threshold_status(~D[2026-08-01])

    assert status.revenue == 46_400
    assert status.warn?, "46,400 of 50,000 is past the 90% warning line"
  end

  test "purchase_period/1 spans the first and last attended dates" do
    %{purchase: purchase} = august_sale(1600)

    assert Reporting.purchase_period(purchase.id) == %{
             first: ~D[2026-08-03],
             last: ~D[2026-08-31]
           }
  end

  test "purchase_period/1 is nil for a purchase with no attendance" do
    {:ok, student} = People.create_student(%{display_name: "Nobody"})
    {:ok, pkg} = monthly_package()

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    assert Reporting.purchase_period(purchase.id) == nil
  end

  describe "month_lanes/1" do
    test "a makeup that did not show up is counted as both" do
      # kind and state are independent facts. A makeup can also be a no-show,
      # and a tally that lets one claim the row loses the other.
      month = ~D[2026-08-01]
      {_slot_a, [to_cancel | _]} = slot_with_sessions(1, month)
      {slot_b, [target | _]} = slot_with_sessions(3, month)

      {:ok, student} = People.create_student(%{display_name: "蘭子"})
      {:ok, pkg} = monthly_package()

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, _} = Roster.enroll(to_cancel, student, purchase)
      {:ok, cancelled} = Studio.cancel_session(to_cancel, "颱風假")
      {:ok, [credit]} = Roster.issue_cancellation_credits(cancelled)
      {:ok, attendance} = Roster.book_makeup(target, student, credit)
      {:ok, _} = Roster.mark_no_show(attendance)

      entry = lane_entry(Reporting.month_lanes(month), slot_b.id, target.id)

      assert entry.total == 1
      assert entry.makeup == 1
      assert entry.no_show == 1
      assert entry.expected == 0
    end

    test "a date nobody signed up for tallies zero rather than going missing" do
      month = ~D[2026-08-01]
      {slot, [first | _]} = slot_with_sessions(1, month)

      entry = lane_entry(Reporting.month_lanes(month), slot.id, first.id)

      assert entry.total == 0
      assert entry.expected == 0
    end

    test "counts only the month asked for" do
      {slot, _august} = slot_with_sessions(1, ~D[2026-08-01])
      {:ok, [september | _]} = Studio.generate_month(slot, ~D[2026-09-01])

      {:ok, student} = People.create_student(%{display_name: "彩華"})
      {:ok, pkg} = monthly_package()

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, _} = Roster.enroll(september, student, purchase)

      august_lane = Enum.find(Reporting.month_lanes(~D[2026-08-01]), &(&1.slot.id == slot.id))

      assert Enum.all?(august_lane.sessions, &(&1.total == 0))
      refute Enum.any?(august_lane.sessions, &(&1.session.date.month == 9))
    end
  end

  describe "open_credits/0" do
    test "orders by expiry with never-expiring credits last" do
      month = ~D[2026-08-01]
      {_slot, [early, late | _]} = slot_with_sessions(1, month)

      {:ok, student} = People.create_student(%{display_name: "宜群"})
      {:ok, pkg} = monthly_package()

      # A package credit expires at the end of its month; a cancellation credit
      # never expires, so it is never the urgent one.
      {:ok, package_purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, _} = Roster.enroll(early, student, package_purchase)
      {:ok, [package_credit]} = Roster.mint_package_credits(package_purchase)

      {:ok, other_purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, _} = Roster.enroll(late, student, other_purchase)
      {:ok, cancelled} = Studio.cancel_session(late, "颱風假")
      {:ok, [cancellation_credit]} = Roster.issue_cancellation_credits(cancelled)

      assert cancellation_credit.expires_on == nil

      assert Enum.map(Reporting.open_credits(~D[2026-08-01]), & &1.id) == [
               package_credit.id,
               cancellation_credit.id
             ]
    end

    test "leaves out credits that are spent or already lapsed" do
      month = ~D[2026-08-01]
      {_slot_a, [origin | _]} = slot_with_sessions(1, month)
      {_slot_b, [target | _]} = slot_with_sessions(3, month)

      {:ok, student} = People.create_student(%{display_name: "允一"})
      {:ok, pkg} = monthly_package()

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, _} = Roster.enroll(origin, student, purchase)
      {:ok, [credit]} = Roster.mint_package_credits(purchase)

      # Past its August expiry, the credit is gone from the open list.
      assert Reporting.open_credits(~D[2026-09-01]) == []

      # And spending it removes it even inside its own month.
      {:ok, _attendance} = Roster.book_makeup(target, student, credit)
      assert Reporting.open_credits(~D[2026-08-01]) == []
    end
  end

  describe "payments_for_month/1" do
    test "includes claims she has not confirmed yet" do
      # Revenue counts confirmed money only, but this list is her work queue:
      # dropping unconfirmed rows would hide the payments needing a decision.
      august_sale(1200, confirm: false)

      assert [payment] = Reporting.payments_for_month(~D[2026-08-01])
      assert payment.state == "claimed"
      assert payment.amount == 1200
      assert payment.purchase.student.display_name
    end

    test "keys on when the money arrived, not on the classes it paid for" do
      august_sale(1200)

      assert Reporting.payments_for_month(~D[2026-09-01]) == []
      assert length(Reporting.payments_for_month(~D[2026-08-01])) == 1
    end
  end

  describe "close_month/1, get_closed_month/1, list_closed_months/1" do
    test "closes a month, freezing its revenue and per-method breakdown" do
      %{} = august_sale(1600)

      {:ok, closed} = Reporting.close_month(~D[2026-08-15])

      assert closed.month == ~D[2026-08-01]
      assert closed.revenue == 1600

      assert closed.revenue_by_method == %{
               "line_pay" => 1600,
               "line_bank" => 0,
               "cash" => 0,
               "other" => 0
             }

      assert closed.tax_threshold == Reporting.monthly_threshold()
      assert Reporting.get_closed_month(~D[2026-08-01]).id == closed.id
    end

    test "get_closed_month/1 is nil for a month that hasn't closed" do
      assert Reporting.get_closed_month(~D[2026-08-01]) == nil
    end

    test "close_month/1 overwrites cleanly when called again" do
      {:ok, _first} = Reporting.close_month(~D[2026-08-01])
      %{} = august_sale(1600)

      {:ok, second} = Reporting.close_month(~D[2026-08-01])

      assert second.revenue == 1600

      assert Reporting.list_closed_months(before: ~D[2026-09-01], limit: 12, offset: 0) == [
               second
             ]
    end

    test "list_closed_months/1 is most-recent-first, strictly before the boundary, paginated" do
      {:ok, jun} = Reporting.close_month(~D[2026-06-01])
      {:ok, jul} = Reporting.close_month(~D[2026-07-01])
      {:ok, aug} = Reporting.close_month(~D[2026-08-01])

      assert Reporting.list_closed_months(before: ~D[2026-09-01], limit: 12, offset: 0) ==
               [aug, jul, jun]

      assert Reporting.list_closed_months(before: ~D[2026-08-01], limit: 12, offset: 0) ==
               [jul, jun]

      assert Reporting.list_closed_months(before: ~D[2026-09-01], limit: 1, offset: 1) == [jul]
    end
  end

  describe "cycle_summary/1" do
    test "reads live for a month that hasn't closed" do
      %{} = august_sale(1600)

      assert Reporting.cycle_summary(~D[2026-08-01]) == %{
               revenue: 1600,
               by_method: Reporting.revenue_by_method_for_month(~D[2026-08-01])
             }
    end

    test "reads the frozen snapshot for a month that has closed" do
      %{} = august_sale(1600)
      {:ok, _} = Reporting.close_month(~D[2026-08-01])

      assert Reporting.cycle_summary(~D[2026-08-01]) == %{
               revenue: 1600,
               by_method: [{"line_pay", 1600}, {"line_bank", 0}, {"cash", 0}, {"other", 0}]
             }
    end
  end

  defp slot_with_sessions(weekday, month) do
    start_time = Time.add(~T[09:30:00], System.unique_integer([:positive]), :second)

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: weekday,
        start_time: start_time,
        end_time: Time.add(start_time, 75, :minute),
        default_style: "基礎",
        label: "slot-#{System.unique_integer([:positive])}"
      })

    {:ok, sessions} = Studio.generate_month(slot, month)
    {slot, sessions}
  end

  defp lane_entry(lanes, slot_id, session_id) do
    lanes
    |> Enum.find(&(&1.slot.id == slot_id))
    |> Map.fetch!(:sessions)
    |> Enum.find(&(&1.session.id == session_id))
  end
end
