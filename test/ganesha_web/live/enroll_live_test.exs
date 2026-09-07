defmodule GaneshaWeb.EnrollLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp august_monday do
    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    %{slot: slot, sessions: sessions, student: student, monthly: monthly}
  end

  test "lists the month's sessions and the students available to enroll", %{conn: conn} do
    %{slot: slot, student: student} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    assert has_element?(view, "#enroll-form")

    assert has_element?(
             view,
             "#session-check-#{Enum.at(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01]), 0).id}"
           )

    assert render(view) =~ student.display_name
  end

  test "falls back instead of crashing on malformed year or month", %{conn: conn} do
    %{slot: slot} = august_monday()

    assert {:ok, _view, html} = live(conn, ~p"/enroll/#{slot.id}/oops/13")
    assert html =~ slot.label
  end

  test "enrolls a student in every session of the month", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id))
    })
    |> render_submit()

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.list_price == 2000
    assert length(Roster.list_for_student(student.id)) == 5
    assert length(Roster.available_credits(student.id, ~D[2026-08-31])) == 1

    assert has_element?(view, "#purchase-#{purchase.id}")
  end

  test "enrolls in a subset of dates and prices only those", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => sessions |> Enum.take(2) |> Enum.map(&to_string(&1.id))
    })
    |> render_submit()

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.list_price == 800
  end

  test "applies a custom amount with a note", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id)),
      "custom_amount" => "1600",
      "note" => "友情價"
    })
    |> render_submit()

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.list_price == 2000
    assert Sales.payable(purchase) == 1600
    assert purchase.note == "友情價"
  end

  test "shows an error when no dates are selected", %{conn: conn} do
    %{slot: slot, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    html =
      view
      |> form("#enroll-form", %{
        "student_id" => student.id,
        "package_id" => monthly.id,
        "session_ids" => []
      })
      |> render_submit()

    assert html =~ "請選擇上課日期"
    assert Sales.list_purchases_for_student(student.id) == []
  end

  test "records a payment against an enrollment", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student, monthly: monthly} = august_monday()

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => monthly.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id))
    })
    |> render_submit()

    [purchase] = Sales.list_purchases_for_student(student.id)

    view
    |> form("#payment-form-#{purchase.id}", %{
      "amount" => "2000",
      "method" => "line_pay",
      "reported_last5" => "12345"
    })
    |> render_submit()

    assert [payment] = Sales.list_payments_for_purchase(purchase.id)
    assert payment.amount == 2000
    assert payment.method == "line_pay"
    assert payment.reported_last5 == "12345"
    assert payment.state == "claimed", "recording is not confirming"
    assert render(view) =~ "NT$ 0 / 2000"
    assert has_element?(view, "#payment-form-#{purchase.id} input[name='amount'][value='2000']")
  end

  test "rejects enrolling a student who has never bought a grandfathered package", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student} = august_monday()

    {:ok, retired} =
      Catalog.create_package(%{
        name: "元老方案",
        kind: "monthly",
        price_per_class: 350,
        active: false,
        grandfather_strategy: "past_purchasers"
      })

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    html =
      view
      |> form("#enroll-form", %{
        "student_id" => student.id,
        "package_id" => retired.id,
        "session_ids" => Enum.map(sessions, &to_string(&1.id))
      })
      |> render_submit()

    assert html =~ "僅開放曾購買過的學生續購"
    assert Sales.list_purchases_for_student(student.id) == []
  end

  test "lets a returning student renew a grandfathered package", %{conn: conn} do
    %{slot: slot, sessions: sessions, student: student} = august_monday()

    {:ok, retired} =
      Catalog.create_package(%{
        name: "元老方案",
        kind: "monthly",
        price_per_class: 350,
        active: false,
        grandfather_strategy: "past_purchasers"
      })

    {:ok, _prior} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: retired.id,
        list_price: 350
      })

    {:ok, view, _html} = live(conn, ~p"/enroll/#{slot.id}/2026/8")

    view
    |> form("#enroll-form", %{
      "student_id" => student.id,
      "package_id" => retired.id,
      "session_ids" => Enum.map(sessions, &to_string(&1.id))
    })
    |> render_submit()

    purchases = Sales.list_purchases_for_student(student.id)
    assert length(purchases) == 2
    # The new enrollment has a slot_id; the seeded prior purchase does not.
    assert new_purchase = Enum.find(purchases, &(&1.slot_id == slot.id))
    assert new_purchase.list_price == 1750
  end
end
