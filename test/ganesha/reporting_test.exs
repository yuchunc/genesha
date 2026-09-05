defmodule Ganesha.ReportingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Reporting, Roster, Sales, Studio}

  defp monthly_package do
    Catalog.create_package(%{
      name: "月課程-#{System.unique_integer([:positive])}",
      kind: "monthly",
      price_per_class: 400
    })
  end

  # Creates an enrolled August purchase and optionally pays it.
  defp august_sale(paid_amount, opts \\ []) do
    confirm? = Keyword.get(opts, :confirm, true)

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: Time.add(~T[09:30:00], System.unique_integer([:positive]), :second),
        end_time: ~T[10:45:00],
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
end
