defmodule GaneshaWeb.SettingsLiveTest do
  use GaneshaWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Ganesha.{Catalog, Publishing}

  setup :register_and_log_in_user

  test "lists packages and lets the price change", %{conn: conn} do
    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#package-#{pkg.id}")

    view
    |> form("#package-form-#{pkg.id}", %{"price_per_class" => "450", "included_makeups" => "1"})
    |> render_submit()

    updated = Catalog.get_package!(pkg.id)
    assert updated.price_per_class == 450
    assert updated.included_makeups == 1
  end

  test "creates a new package", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#new-package-form", %{
      "package" => %{
        "name" => "暑期加開",
        "kind" => "drop_in",
        "price_per_class" => "500",
        "included_makeups" => "0"
      }
    })
    |> render_submit()

    assert Enum.any?(Catalog.list_packages(), &(&1.name == "暑期加開" and &1.price_per_class == 500))
    assert render(view) =~ "暑期加開"
  end

  test "saves the bank details used by the announcement footer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#studio-settings-form", %{
      "settings" => %{
        "bank_name" => "連線商業銀行",
        "bank_code" => "824",
        "account_number" => "111001756051",
        "transfer_deadline" => "8/15",
        "closing_note" => "＊＊或者 line pay Money"
      }
    })
    |> render_submit()

    settings = Publishing.get_settings()
    assert settings.bank_code == "824"
    assert settings.transfer_deadline == "8/15"
  end

  test "a changed package price flows into the announcement", %{conn: conn} do
    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, slot} =
      Ganesha.Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, _} = Ganesha.Studio.generate_month(slot, ~D[2026-08-01])

    {:ok, _} = Catalog.update_package(pkg, %{price_per_class: 500})

    {:ok, view, _html} = live(conn, ~p"/publish/2026/8")
    assert render(view) =~ "2500元 /5 堂"
  end
end
