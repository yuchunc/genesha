defmodule GaneshaWeb.PublishLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Studio}

  setup :register_and_log_in_user

  test "renders the announcement text and a copy button", %{conn: conn} do
    {:ok, _} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/publish/2026/8")

    assert has_element?(view, "#announcement-text")
    assert has_element?(view, "#copy-announcement")
    assert render(view) =~ "早晨練習｜週一 基礎瑜伽"
    assert render(view) =~ "8月開課時間表"
  end

  test "shows the roster block for her own reference", %{conn: conn} do
    {:ok, _} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, view, _html} = live(conn, ~p"/publish/2026/8")
    assert has_element?(view, "#roster-text")
  end
end
