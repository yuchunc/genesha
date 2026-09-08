defmodule GaneshaWeb.ScheduleLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.Studio

  setup :register_and_log_in_user

  test "creates a standalone session and returns to its month", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8")

    {:ok, _view, _html} =
      view
      |> form("#standalone-form", %{
        "session" => %{
          "date" => "2026-08-20",
          "start_time" => "19:00",
          "end_time" => "20:00",
          "label" => "期間限定：中秋瑜伽",
          "style" => "流動"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/month/2026/8")

    assert [session] = Studio.sessions_in_month(~D[2026-08-01])
    assert session.slot_id == nil
    assert session.label == "期間限定：中秋瑜伽"
    assert session.start_time == ~T[19:00:00]
  end

  test "creates a recurring class and generates it for the viewed month", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8&mode=recurring")

    {:ok, _view, _html} =
      view
      |> form("#recurring-form", %{
        "slot" => %{
          "weekday" => "1",
          "start_time" => "09:30",
          "end_time" => "10:45",
          "label" => "早晨練習｜週一 基礎瑜伽",
          "default_style" => "基礎"
        }
      })
      |> render_submit()
      |> follow_redirect(conn, ~p"/month/2026/8")

    assert [slot] = Studio.list_active_slots()
    assert length(Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01])) == 5
  end

  test "switches between the standalone and recurring forms", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8")

    assert has_element?(view, "#standalone-form")
    refute has_element?(view, "#recurring-form")

    view |> element("#mode-recurring") |> render_click()
    assert_patch(view, ~p"/month/new?year=2026&month=8&mode=recurring")

    assert has_element?(view, "#recurring-form")
    refute has_element?(view, "#standalone-form")
  end

  test "shows a specific error when a recurring class already exists for that weekday and time",
       %{conn: conn} do
    {:ok, _existing} =
      Ganesha.Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, view, _html} = live(conn, ~p"/month/new?year=2026&month=8&mode=recurring")

    html =
      view
      |> form("#recurring-form", %{
        "slot" => %{
          "weekday" => "1",
          "start_time" => "09:30",
          "end_time" => "11:00",
          "label" => "另一堂課",
          "default_style" => "流動"
        }
      })
      |> render_submit()

    assert html =~ "已經有相同星期與時間的固定班次了"
  end
end
