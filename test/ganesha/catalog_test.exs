defmodule Ganesha.CatalogTest do
  use Ganesha.DataCase, async: true
  alias Ganesha.Catalog
  alias Ganesha.Catalog.Package

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
