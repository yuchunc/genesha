defmodule Ganesha.Assistant.Tasks.SavePackageTest do
  use Ganesha.DataCase

  alias Ganesha.Catalog
  alias Ganesha.Assistant.Tasks.SavePackage

  test "creates a package" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}

    input = %{
      "name" => "晚間單堂",
      "kind" => "drop_in",
      "price_per_class" => 450,
      "included_makeups" => 0,
      "active" => true,
      "grandfather_strategy" => "none"
    }

    assert {:ok, %{parsed: parsed}} = SavePackage.propose(input, ctx)
    assert {:ok, {_, package_id}} = SavePackage.apply(parsed, "line:teacher")
    assert Catalog.get_package!(package_id).price_per_class == 450
  end

  test "edits a package and fails if it changed after propose" do
    ctx = %{locale: "zh-TW", today: ~D[2026-10-02]}
    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    input = %{
      "package_id" => package.id,
      "price_per_class" => 420,
      "included_makeups" => 1,
      "active" => true,
      "grandfather_strategy" => "none"
    }

    assert {:ok, %{parsed: parsed}} = SavePackage.propose(input, ctx)
    {:ok, _} = Catalog.update_package(package, %{price_per_class: 500})
    assert {:error, :package_changed} = SavePackage.apply(parsed, "line:teacher")
  end

  test "summary describes a new package, and only the changed fields of an edit" do
    create = %{
      "mode" => "create",
      "name" => "晚間單堂",
      "kind" => "drop_in",
      "price_per_class" => 450,
      "included_makeups" => 0,
      "active" => true,
      "grandfather_strategy" => "none"
    }

    for locale <- ["zh-TW", "en"] do
      text = SavePackage.summary(create, locale)
      assert text =~ "晚間單堂"
      assert text =~ "NT$450"
    end

    update = %{
      "mode" => "update",
      "name" => "月課程",
      "kind" => "monthly",
      "price_per_class" => 420,
      "included_makeups" => 1,
      "active" => true,
      "grandfather_strategy" => "none",
      "before_price_per_class" => 400,
      "before_included_makeups" => 1,
      "before_active" => true,
      "before_grandfather_strategy" => "none"
    }

    text = SavePackage.summary(update, "zh-TW")
    assert text =~ "NT$400"
    assert text =~ "NT$420"
    refute text =~ "補課"
  end
end
