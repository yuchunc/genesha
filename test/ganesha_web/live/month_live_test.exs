defmodule GaneshaWeb.MonthLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  setup :register_and_log_in_user

  defp monday_slot do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    slot
  end

  test "calendar shows a mark with the attendee count on the session's date", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "蘭子"})
    {:ok, pkg} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    {:ok, view, _html} = live(conn, ~p"/class/2026/8")

    assert has_element?(view, "#cal-2026-08-03", "1")
    assert has_element?(view, "#date-2026-08-03")
    assert has_element?(view, "#session-#{session.id}")
  end

  test "shows the copy-previous-month prompt only when this month is empty and last month had classes",
       %{conn: conn} do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/9")
    assert has_element?(view, "#copy-prompt")

    view |> element("#copy-previous-month") |> render_click()

    refute has_element?(view, "#copy-prompt")
    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-09-01])) > 0
  end

  test "dismissing the copy prompt hides it without copying anything", %{conn: conn} do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/9")

    view |> element("#dismiss-copy-prompt") |> render_click()

    refute has_element?(view, "#copy-prompt")
    assert Studio.sessions_for_slot_in_month(slot, ~D[2026-09-01]) == []
  end

  test "does not show the copy prompt once this month already has a recurring session", %{
    conn: conn
  } do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, _} = Studio.generate_month(slot, ~D[2026-09-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/9")

    refute has_element?(view, "#copy-prompt")
  end

  test "overrides the style for a single session", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/8")

    view
    |> form("#style-form-#{session.id}", %{"style" => "流動"})
    |> render_submit()

    assert Studio.get_session!(session.id).style == "流動"
  end

  test "cancelling a session issues portable credits to the enrolled students", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, student} = People.create_student(%{display_name: "蘭子"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    {:ok, view, _html} = live(conn, ~p"/class/2026/8")

    view
    |> form("#cancel-form-#{session.id}", %{"reason" => "颱風假"})
    |> render_submit()

    assert Studio.get_session!(session.id).state == "cancelled"

    assert [credit] = Roster.available_credits(student.id, ~D[2026-12-01])
    assert credit.source == "cancellation"
    assert is_nil(credit.expires_on)
  end

  test "cancelling without a reason shows an error and changes nothing", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/8")

    html =
      view
      |> form("#cancel-form-#{session.id}", %{"reason" => ""})
      |> render_submit()

    assert html =~ "請填寫停課原因"
    assert Studio.get_session!(session.id).state == "scheduled"
  end

  test "agenda groups two sessions on the same date under one heading", %{conn: conn} do
    monday = monday_slot()

    {:ok, evening} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "流動",
        label: "晚間練習｜週一 流動瑜伽"
      })

    {:ok, [morning_session | _]} = Studio.generate_month(monday, ~D[2026-08-01])
    {:ok, [evening_session | _]} = Studio.generate_month(evening, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/8")

    assert has_element?(view, "#date-2026-08-03 #session-#{morning_session.id}")
    assert has_element?(view, "#date-2026-08-03 #session-#{evening_session.id}")
  end

  test "the roster shortcut links to the enroll flow for an active slot with sessions", %{
    conn: conn
  } do
    slot = monday_slot()
    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/class/2026/8")

    assert has_element?(view, "#enroll-slot-#{slot.id}")
  end
end
