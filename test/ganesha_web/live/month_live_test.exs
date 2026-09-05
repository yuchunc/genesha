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

  test "generates a month's sessions on demand", %{conn: conn} do
    slot = monday_slot()

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    view |> element("#generate-slot-#{slot.id}") |> render_click()

    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01])) == 5
    assert has_element?(view, "#slot-#{slot.id}")
    assert has_element?(view, "#enroll-slot-#{slot.id}")
    assert has_element?(view, "[data-date='2026-08-03']")
  end

  test "overrides the style for a single session", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

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

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    view
    |> form("#cancel-form-#{session.id}", %{"reason" => "颱風假"})
    |> render_submit()

    assert Studio.get_session!(session.id).state == "cancelled"

    # A cancellation credit never expires, so it is available far in the future.
    assert [credit] = Roster.available_credits(student.id, ~D[2026-12-01])
    assert credit.source == "cancellation"
    assert is_nil(credit.expires_on)
  end

  test "cancelling without a reason shows an error and changes nothing", %{conn: conn} do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/month/2026/8")

    html =
      view
      |> form("#cancel-form-#{session.id}", %{"reason" => ""})
      |> render_submit()

    assert html =~ "請填寫停課原因"
    assert Studio.get_session!(session.id).state == "scheduled"
  end
end
