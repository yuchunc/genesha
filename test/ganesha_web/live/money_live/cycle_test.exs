defmodule GaneshaWeb.MoneyLive.CycleTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, People, Repo, Reporting, Sales}

  setup :register_and_log_in_user

  defp student_with_purchase(amount \\ 1600) do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: amount})

    %{student: student, purchase: purchase}
  end

  test "shows every payment recorded in the cycle, whatever its state", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_pay",
        paid_on: ~D[2026-08-05]
      })

    {:ok, view, _html} = live(conn, ~p"/money/2026/8")

    assert has_element?(view, "#payment-#{payment.id}")
    assert render(view) =~ student.display_name
  end

  test "falls back to the current cycle on a malformed year or month", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/money/not-a-year/13")
    assert has_element?(view, "#cycle-revenue")
  end

  test "breaks confirmed revenue down by method", %{conn: conn} do
    %{purchase: purchase} = student_with_purchase()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: ~D[2026-08-05]
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")

    {:ok, view, _html} = live(conn, ~p"/money/2026/8")

    assert render(view) =~ "現金"
    assert has_element?(view, "#cycle-revenue[data-amount='1600']")
  end

  test "confirming a payment here records the confirmer, same as the student page", %{
    conn: conn
  } do
    %{purchase: purchase} = student_with_purchase()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_pay",
        paid_on: ~D[2026-08-05]
      })

    {:ok, view, _html} = live(conn, ~p"/money/2026/8")

    view |> element("#confirm-payment-#{payment.id}") |> render_click()

    confirmed = Repo.reload!(payment)
    assert confirmed.state == "confirmed"
    refute is_nil(confirmed.confirmed_by)
  end

  test "flags a suspicious repeat of the same last-five digits", %{conn: conn} do
    %{purchase: purchase} = student_with_purchase()
    {:ok, other_student} = People.create_student(%{display_name: "靖心"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, other_purchase} =
      Sales.create_purchase(%{student_id: other_student.id, package_id: pkg.id, list_price: 450})

    {:ok, _} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_pay",
        paid_on: ~D[2026-08-05],
        reported_last5: "12345"
      })

    {:ok, dup} =
      Sales.record_payment(%{
        purchase_id: other_purchase.id,
        amount: 450,
        method: "line_pay",
        paid_on: ~D[2026-08-06],
        reported_last5: "12345"
      })

    {:ok, view, _html} = live(conn, ~p"/money/2026/8")
    assert has_element?(view, "#payment-#{dup.id}[data-suspicious=true]")
  end

  test "shows an empty state when nothing was recorded that cycle", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/money/2020/1")
    assert has_element?(view, "#no-payments")
  end

  test "a closed month reads its frozen snapshot instead of recomputing live", %{conn: conn} do
    %{purchase: purchase} = student_with_purchase()
    past_month = ~D[2026-07-01]

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: past_month
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    {:ok, closed} = Reporting.close_month(past_month)

    # Overwrite the frozen row directly, bypassing what live computation
    # would currently produce, to prove the detail view reads the snapshot
    # rather than recomputing it on every visit.
    closed |> Ecto.Changeset.change(revenue: 9999) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/money/2026/7")

    assert has_element?(view, "#cycle-revenue[data-amount='9999']")
  end
end
