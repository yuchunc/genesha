defmodule GaneshaWeb.TodayLiveTest do
  use GaneshaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp session_today do
    today = Clock.today()

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: Date.day_of_week(today),
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜基礎瑜伽"
      })

    {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: today, style: "基礎"})
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 1600
      })

    {:ok, attendance} = Roster.enroll(session, student, purchase)
    %{session: session, attendance: attendance}
  end

  test "shows the next session and its roster", %{conn: conn} do
    %{attendance: attendance} = session_today()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#today-session")
    assert has_element?(view, "#attendance-#{attendance.id}")
  end

  test "toggles a student between expected and no-show", %{conn: conn} do
    %{attendance: attendance} = session_today()

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#no-show-#{attendance.id}") |> render_click()
    assert has_element?(view, "#attendance-#{attendance.id}[data-state=no_show]")

    view |> element("#no-show-#{attendance.id}") |> render_click()
    assert has_element?(view, "#attendance-#{attendance.id}[data-state=expected]")
  end

  test "shows an empty state when nothing is scheduled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#no-upcoming-session")
  end

  test "the bottom navigation is present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#bottom-nav")
    assert has_element?(view, "#nav-money")
  end
end
