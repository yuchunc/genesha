defmodule Ganesha.Assistant.Tasks.OverridePriceTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.OverridePrice

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 1600})

    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}, student: student, purchase: purchase}
  end

  test "propose captures payable before and after", c do
    assert {:ok, %{parsed: parsed}} =
             OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    assert parsed["before_payable"] == 1600
    assert parsed["after_payable"] == 1500
    assert parsed["before_custom_amount"] == nil
  end

  test "apply updates the purchase", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    assert {:ok, {_, purchase_id}} = OverridePrice.apply(parsed, "line:teacher")
    assert Sales.payable(Sales.get_purchase!(purchase_id)) == 1500
  end

  test "apply fails if custom_amount changed after propose", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    {:ok, _} = Sales.update_purchase(c.purchase, %{custom_amount: 1400})
    assert {:error, :purchase_changed} = OverridePrice.apply(parsed, "line:teacher")
  end

  test "describe shows owed before → after", c do
    {:ok, %{parsed: parsed}} =
      OverridePrice.propose(%{"purchase_id" => c.purchase.id, "custom_amount" => 1500}, c.ctx)

    assert [{_, before, after_value}] = OverridePrice.describe(parsed, "zh-TW").changes
    assert before == Format.money(1600)
    assert after_value == Format.money(1500)
  end
end
