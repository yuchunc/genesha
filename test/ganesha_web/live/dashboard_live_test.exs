defmodule GaneshaWeb.DashboardLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Clock, Enrolling, People, Studio}

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

    {:ok, _} =
      Enrolling.enroll_month(%{
        student: student,
        slot: slot,
        package: pkg,
        sessions: [session],
        custom_amount: nil,
        note: nil
      })

    session
  end

  test "the root path renders the day variant", %{conn: conn} do
    session = session_today()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#variant-picker")
    assert has_element?(view, "#dash-next-session")
    assert render(view) =~ "Lulu"
    assert has_element?(view, "#bottom-nav")
    assert has_element?(view, "#nav-dashboard")
    refute has_element?(view, "#nav-today")

    _ = session
  end

  test "shows an invitation when nothing is scheduled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#dash-no-session")
  end

  test "switches to the four-lane and ledger variants via the picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#variant-b") |> render_click()
    assert_patch(view, ~p"/dashboard/b")
    assert has_element?(view, "#dash-lanes")

    view |> element("#variant-c") |> render_click()
    assert_patch(view, ~p"/dashboard/c")
    assert has_element?(view, "#dash-ledger")
  end
end
