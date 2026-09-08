defmodule GaneshaWeb.SessionLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp august do
    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, monday} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, friday} =
      Studio.create_slot(%{
        weekday: 5,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週五 基礎瑜伽"
      })

    {:ok, mondays} = Studio.generate_month(monday, ~D[2026-08-01])
    {:ok, fridays} = Studio.generate_month(friday, ~D[2026-08-01])

    %{monthly: monthly, drop_in: drop_in, monday: monday, mondays: mondays, fridays: fridays}
  end

  test "shows the roster for a session", %{conn: conn} do
    %{mondays: mondays, monday: monday, monthly: monthly} = august()
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: student,
        slot: monday,
        package: monthly,
        sessions: mondays,
        custom_amount: nil,
        note: nil
      })

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    assert render(view) =~ "Lulu"
    assert has_element?(view, "#one-off-form")
  end

  test "toggles a student between expected and no-show", %{conn: conn} do
    %{mondays: mondays, monday: monday, monthly: monthly} = august()
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, %{attendances: [attendance]}} =
      Enrolling.enroll_month(%{
        student: student,
        slot: monday,
        package: monthly,
        sessions: [hd(mondays)],
        custom_amount: nil,
        note: nil
      })

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> element("#no-show-#{attendance.id}") |> render_click()
    assert has_element?(view, "#attendance-#{attendance.id}[data-state=no_show]")

    view |> element("#no-show-#{attendance.id}") |> render_click()
    assert has_element?(view, "#attendance-#{attendance.id}[data-state=expected]")
  end

  test "adds a drop-in to the session", %{conn: conn} do
    %{mondays: mondays, drop_in: drop_in} = august()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view
    |> form("#one-off-form", %{"student_id" => jennifer.id, "package_id" => drop_in.id})
    |> render_submit()

    assert [attendance] = Roster.list_for_student(jennifer.id)
    assert attendance.kind == "drop_in"
    assert [purchase] = Sales.list_purchases_for_student(jennifer.id)
    assert Sales.payable(purchase) == 450
  end

  test "books a makeup using an available credit on another weekday", %{conn: conn} do
    %{mondays: mondays, fridays: fridays, monday: monday, monthly: monthly} = august()
    {:ok, lanzi} = People.create_student(%{display_name: "蘭子"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: lanzi,
        slot: monday,
        package: monthly,
        sessions: mondays,
        custom_amount: nil,
        note: nil
      })

    friday = hd(fridays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{friday.id}")

    assert has_element?(view, "#makeup-form")

    view
    |> form("#makeup-form", %{"student_id" => lanzi.id})
    |> render_submit()

    makeup = Enum.find(Roster.list_for_student(lanzi.id), &(&1.kind == "makeup"))
    refute is_nil(makeup)
    assert is_nil(makeup.purchase_id), "a makeup is paid for by a credit, not a sale"
    assert Roster.available_credits(lanzi.id, friday.date) == []
  end

  test "offers no makeup form when nobody holds a usable credit", %{conn: conn} do
    %{fridays: fridays} = august()

    {:ok, view, _html} = live(conn, ~p"/sessions/#{hd(fridays).id}")
    refute has_element?(view, "#makeup-form")
  end

  test "hides one-off and makeup forms for cancelled sessions", %{conn: conn} do
    %{mondays: mondays, fridays: fridays, monday: monday, monthly: monthly} = august()
    {:ok, lanzi} = People.create_student(%{display_name: "蘭子"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: lanzi,
        slot: monday,
        package: monthly,
        sessions: mondays,
        custom_amount: nil,
        note: nil
      })

    {:ok, cancelled} = Studio.cancel_session(hd(fridays), "颱風假")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{cancelled.id}")

    refute has_element?(view, "#one-off-form")
    refute has_element?(view, "#makeup-form")
  end

  test "guards one-off and makeup submissions for cancelled sessions", %{conn: conn} do
    %{mondays: mondays, fridays: fridays, monday: monday, monthly: monthly, drop_in: drop_in} =
      august()

    {:ok, drop_student} = People.create_student(%{display_name: "Jennifer"})
    {:ok, makeup_student} = People.create_student(%{display_name: "蘭子"})

    {:ok, %{credits: [credit]}} =
      Enrolling.enroll_month(%{
        student: makeup_student,
        slot: monday,
        package: monthly,
        sessions: mondays,
        custom_amount: nil,
        note: nil
      })

    {:ok, cancelled} = Studio.cancel_session(hd(fridays), "颱風假")
    {:ok, view, _html} = live(conn, ~p"/sessions/#{cancelled.id}")

    render_submit(view, "add_one_off", %{
      "student_id" => drop_student.id,
      "package_id" => drop_in.id
    })

    render_submit(view, "book_makeup", %{"student_id" => makeup_student.id})

    assert Sales.list_purchases_for_student(drop_student.id) == []
    assert Roster.list_for_student(drop_student.id) == []

    assert Enum.find(Roster.list_for_student(makeup_student.id), &(&1.session.id == cancelled.id)) ==
             nil

    assert [available] = Roster.available_credits(makeup_student.id, cancelled.date)
    assert available.id == credit.id
  end

  test "reports the reason when a makeup cannot be booked", %{conn: conn} do
    %{mondays: mondays, monday: monday, monthly: monthly} = august()
    {:ok, lanzi} = People.create_student(%{display_name: "蘭子"})

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: lanzi,
        slot: monday,
        package: monthly,
        sessions: mondays,
        custom_amount: nil,
        note: nil
      })

    # The credit expires at the end of August, so a September session refuses it.
    {:ok, tuesday} =
      Studio.create_slot(%{
        weekday: 2,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "週二"
      })

    {:ok, september} = Studio.generate_month(tuesday, ~D[2026-09-01])

    {:ok, view, _html} = live(conn, ~p"/sessions/#{hd(september).id}")

    refute has_element?(view, "#makeup-form"),
           "an expired credit must not be offered for a later month"
  end

  test "rejects a one-off for a student who has never bought a grandfathered package", %{
    conn: conn
  } do
    %{mondays: mondays} = august()
    {:ok, student} = People.create_student(%{display_name: "素容"})

    {:ok, retired} =
      Catalog.create_package(%{
        name: "舊生單堂",
        kind: "drop_in",
        price_per_class: 350,
        active: false,
        grandfather_strategy: "past_purchasers"
      })

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    html =
      view
      |> form("#one-off-form", %{"student_id" => student.id, "package_id" => retired.id})
      |> render_submit()

    assert html =~ "僅開放曾購買過的學生續購"
    assert Sales.list_purchases_for_student(student.id) == []
  end

  test "shows a standalone session with no slot", %{conn: conn} do
    {:ok, session} =
      Studio.create_session(%{
        date: ~D[2026-08-20],
        start_time: ~T[19:00:00],
        end_time: ~T[20:30:00],
        label: "期間限定：滿月瑜伽",
        style: "流動",
        state: "scheduled"
      })

    {:ok, _view, html} = live(conn, ~p"/sessions/#{session.id}")

    assert html =~ "滿月瑜伽"
    assert html =~ "19:00–20:30"
  end

  test "lets a returning student buy a grandfathered drop-in again", %{conn: conn} do
    %{mondays: mondays} = august()
    {:ok, student} = People.create_student(%{display_name: "素容"})

    {:ok, retired} =
      Catalog.create_package(%{
        name: "舊生單堂",
        kind: "drop_in",
        price_per_class: 350,
        active: false,
        grandfather_strategy: "past_purchasers"
      })

    {:ok, _prior} =
      Sales.create_purchase(%{student_id: student.id, package_id: retired.id, list_price: 350})

    session = hd(mondays)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view
    |> form("#one-off-form", %{"student_id" => student.id, "package_id" => retired.id})
    |> render_submit()

    assert [attendance] =
             Roster.list_for_session(session) |> Enum.filter(&(&1.student_id == student.id))

    assert attendance.kind == "drop_in"
  end
end
