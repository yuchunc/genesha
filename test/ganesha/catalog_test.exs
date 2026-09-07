defmodule Ganesha.CatalogTest do
  use Ganesha.DataCase
  alias Ganesha.Catalog
  alias Ganesha.Catalog.Package

  test "lists active packages and all packages with active packages first" do
    assert {:ok, active} =
             Catalog.create_package(%{
               name: "active package",
               kind: "monthly",
               price_per_class: 400
             })

    assert {:ok, inactive} =
             Catalog.create_package(%{
               name: "inactive package",
               kind: "drop_in",
               price_per_class: 450,
               active: false
             })

    assert Catalog.list_active_packages() == [active]
    assert Catalog.list_packages() == [active, inactive]
  end

  describe "package_available?/2 and list_selectable_packages/0" do
    test "an active package is available to anyone" do
      {:ok, pkg} =
        Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

      assert Catalog.package_available?(pkg, MapSet.new())
    end

    test "an inactive package with no grandfather strategy is closed to everyone" do
      {:ok, pkg} =
        Catalog.create_package(%{
          name: "舊方案",
          kind: "drop_in",
          price_per_class: 450,
          active: false
        })

      refute Catalog.package_available?(pkg, MapSet.new([pkg.id]))
      refute Catalog.package_available?(pkg, MapSet.new())
      refute pkg in Catalog.list_selectable_packages()
    end

    test "an inactive past_purchasers package is open only to a student who already holds it" do
      {:ok, pkg} =
        Catalog.create_package(%{
          name: "元老方案",
          kind: "monthly",
          price_per_class: 350,
          active: false,
          grandfather_strategy: "past_purchasers"
        })

      assert Catalog.package_available?(pkg, MapSet.new([pkg.id]))
      refute Catalog.package_available?(pkg, MapSet.new())
      assert pkg in Catalog.list_selectable_packages()
    end
  end

  test "creates a monthly package granting one makeup" do
    assert {:ok, pkg} =
             Catalog.create_package(%{
               name: "月課程",
               kind: "monthly",
               price_per_class: 400,
               included_makeups: 1
             })

    assert pkg.kind == "monthly"
    assert pkg.included_makeups == 1
    assert pkg.active
  end

  test "defaults included_makeups to zero" do
    assert {:ok, pkg} =
             Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    assert pkg.included_makeups == 0
  end

  test "rejects an unknown kind" do
    assert {:error, cs} =
             Catalog.create_package(%{name: "x", kind: "weekly", price_per_class: 1})

    assert "is invalid" in errors_on(cs).kind
  end

  test "rejects a negative price" do
    assert {:error, cs} =
             Catalog.create_package(%{name: "x", kind: "trial", price_per_class: -1})

    assert "must be greater than or equal to 0" in errors_on(cs).price_per_class
  end

  test "rejects explicit nil for database-required defaults" do
    assert {:error, cs} =
             Catalog.create_package(%{
               name: "x",
               kind: "trial",
               price_per_class: 450,
               included_makeups: nil,
               active: nil
             })

    assert "can't be blank" in errors_on(cs).included_makeups
    assert "can't be blank" in errors_on(cs).active
  end

  test "package names are unique" do
    {:ok, _} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    assert {:error, cs} =
             Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    assert "has already been taken" in errors_on(cs).name
  end

  describe "price_for/2 — the numbers from the August document" do
    test "monthly package at 400 per class" do
      pkg = %Package{price_per_class: 400}
      assert Catalog.price_for(pkg, 4) == 1600
      assert Catalog.price_for(pkg, 3) == 1200
      # 彩華's two classes at the package rate.
      assert Catalog.price_for(pkg, 2) == 800
    end

    test "drop-in at 450 per class" do
      pkg = %Package{price_per_class: 450}
      assert Catalog.price_for(pkg, 1) == 450
      # 素容's two classes at the drop-in rate.
      assert Catalog.price_for(pkg, 2) == 900
    end
  end
end
