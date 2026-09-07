defmodule GaneshaWeb.MoneyLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Reporting, Sales}

  setup :register_and_log_in_user

  defp confirmed_sale(amount) do
    {:ok, student} =
      People.create_student(%{display_name: "S#{System.unique_integer([:positive])}"})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "pkg-#{System.unique_integer([:positive])}",
        kind: "monthly",
        price_per_class: 400
      })

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: amount})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: amount,
        method: "line_pay",
        paid_on: Clock.today()
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    student
  end

  test "lists students who still owe money and shows the revenue gauge", %{conn: conn} do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    {:ok, view, _html} = live(conn, ~p"/money")

    assert has_element?(view, "#owing-#{student.id}")
    assert has_element?(view, "#revenue")
    assert has_element?(view, "#tax-gauge")
  end

  test "shows a settled state when nothing is owed", %{conn: conn} do
    _student = confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#nothing-owed")
  end

  test "stays quiet about the tax threshold at low revenue", %{conn: conn} do
    _student = confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    refute has_element?(view, "#tax-warning")
  end

  test "warns when the month approaches NT$50,000", %{conn: conn} do
    for _ <- 1..29, do: confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#tax-warning")
  end

  test "the current cycle links through to its detail view", %{conn: conn} do
    today = Clock.today()
    {:ok, view, _html} = live(conn, ~p"/money")

    html = view |> element("#current-cycle") |> render()
    assert html =~ ~s(href="/money/#{today.year}/#{today.month}")
  end

  test "shows a revenue trend chart across recent cycles", %{conn: conn} do
    _student = confirmed_sale(1600)

    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#revenue-chart")
  end

  test "pages into history without repeating the current cycle, hiding 更早 once exhausted",
       %{conn: conn} do
    today = Clock.today()

    for offset <- 1..13 do
      Reporting.close_month(Date.shift(Date.beginning_of_month(today), month: -offset))
    end

    {:ok, view, _html} = live(conn, ~p"/money")

    refute has_element?(view, "#cycle-#{today.year}-#{today.month}")
    assert has_element?(view, "a", "更早")

    view |> element("a", "更早") |> render_click()
    assert_patch(view, ~p"/money?page=1")

    assert has_element?(view, "a", "較近")
    refute has_element?(view, "a", "更早")
  end

  test "shows a closed month's frozen revenue in history", %{conn: conn} do
    past_month = Date.shift(Date.beginning_of_month(Clock.today()), month: -1)
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: past_month
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")
    {:ok, _} = Reporting.close_month(past_month)

    {:ok, view, _html} = live(conn, ~p"/money")

    assert has_element?(view, "#cycle-#{past_month.year}-#{past_month.month}")
    html = view |> element("#cycle-#{past_month.year}-#{past_month.month}") |> render()
    assert html =~ "1,600"
  end

  test "history shows nothing when no month has closed yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/money")
    assert has_element?(view, "#no-history")
  end
end
