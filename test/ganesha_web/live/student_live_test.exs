defmodule GaneshaWeb.StudentLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Repo, Sales}

  setup :register_and_log_in_user

  defp student_with_purchase do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    %{student: student, purchase: purchase}
  end

  test "lists students", %{conn: conn} do
    %{student: student} = student_with_purchase()

    {:ok, view, _html} = live(conn, ~p"/students")
    assert has_element?(view, "#student-#{student.id}")
  end

  test "creates a student", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/students")

    view
    |> form("#student-form", %{"student" => %{"display_name" => "Carita"}})
    |> render_submit()

    assert render(view) =~ "Carita"
  end

  test "shows purchases and the outstanding balance", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    assert has_element?(view, "#purchase-#{purchase.id}")
    assert has_element?(view, "#outstanding")
    assert render(view) =~ "1600"
  end

  test "confirming a payment records the confirmer and clears the balance", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_pay",
        paid_on: Clock.today()
      })

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    view |> element("#confirm-payment-#{payment.id}") |> render_click()

    confirmed = Repo.reload!(payment)
    assert confirmed.state == "confirmed"
    refute is_nil(confirmed.confirmed_by)
    refute is_nil(confirmed.confirmed_at)

    assert has_element?(view, "#outstanding[data-amount='0']")
  end

  test "records a custom amount override with a note", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    view
    |> form("#override-form-#{purchase.id}", %{
      "custom_amount" => "0",
      "note" => "按摩器代購"
    })
    |> render_submit()

    updated = Repo.reload!(purchase)
    assert updated.custom_amount == 0
    assert updated.note == "按摩器代購"
    assert has_element?(view, "#outstanding[data-amount='0']")
  end

  test "clearing the override field restores the list price", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()
    {:ok, _} = Sales.update_purchase(purchase, %{custom_amount: 0})

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    view
    |> form("#override-form-#{purchase.id}", %{"custom_amount" => "", "note" => ""})
    |> render_submit()

    assert is_nil(Repo.reload!(purchase).custom_amount)
    assert has_element?(view, "#outstanding[data-amount='1600']")
  end

  test "flags a suspicious repeated last5 on the same purchase", %{conn: conn} do
    %{student: student, purchase: purchase} = student_with_purchase()
    today = Clock.today()

    for _ <- 1..2 do
      {:ok, _} =
        Sales.record_payment(%{
          purchase_id: purchase.id,
          amount: 1600,
          method: "line_pay",
          paid_on: today,
          reported_last5: "99999"
        })
    end

    {:ok, view, _html} = live(conn, ~p"/students/#{student.id}")

    assert has_element?(view, "[data-suspicious=true]")
  end
end
