defmodule GaneshaWeb.MoneyLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Sales}

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
end
