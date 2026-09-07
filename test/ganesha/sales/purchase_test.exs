defmodule Ganesha.Sales.PurchaseTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Sales}

  defp student_and_monthly do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, monthly} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {student, monthly}
  end

  test "payable/1 is list_price when there is no override" do
    {student, monthly} = student_and_monthly()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1600
      })

    assert Sales.payable(purchase) == 1600
  end

  test "payable/1 uses the override, and zero is a real value" do
    {student, monthly} = student_and_monthly()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1600,
        custom_amount: 0,
        note: "按摩器代購"
      })

    assert Sales.payable(purchase) == 0
    assert purchase.note == "按摩器代購"
  end

  test "the override may exceed the list price" do
    {student, monthly} = student_and_monthly()

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1200,
        custom_amount: 1500
      })

    assert Sales.payable(purchase) == 1500
  end

  test "rejects a negative list price or override" do
    {student, monthly} = student_and_monthly()
    base = %{student_id: student.id, package_id: monthly.id}

    assert {:error, cs} = Sales.create_purchase(Map.put(base, :list_price, -1))
    assert "must be greater than or equal to 0" in errors_on(cs).list_price

    attrs = base |> Map.put(:list_price, 100) |> Map.put(:custom_amount, -5)
    assert {:error, cs} = Sales.create_purchase(attrs)
    assert "must be greater than or equal to 0" in errors_on(cs).custom_amount
  end

  test "both of the August two-class prices are representable and distinguishable" do
    {student, monthly} = student_and_monthly()

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    # 素容: two classes bought at the drop-in rate = 900.
    {:ok, su} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: drop_in.id,
        list_price: Catalog.price_for(drop_in, 2)
      })

    # 彩華: two classes bought at the monthly package rate = 800.
    {:ok, cai} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: Catalog.price_for(monthly, 2)
      })

    assert Sales.payable(su) == 900
    assert Sales.payable(cai) == 800
    refute su.package_id == cai.package_id
  end

  test "list_purchases_for_student/1 preloads the package" do
    {student, monthly} = student_and_monthly()

    {:ok, _} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        list_price: 1600
      })

    assert [purchase] = Sales.list_purchases_for_student(student.id)
    assert purchase.package.name == "月課程"
  end

  test "purchased_package_ids_for_student/1 collects every package ever bought, once each" do
    {student, monthly} = student_and_monthly()

    {:ok, drop_in} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: monthly.id, list_price: 1600})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: monthly.id, list_price: 1600})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: drop_in.id, list_price: 450})

    ids = Sales.purchased_package_ids_for_student(student.id)
    assert ids == MapSet.new([monthly.id, drop_in.id])
  end

  test "purchased_package_ids_for_student/1 is empty for a student who has never bought anything" do
    {:ok, student} = People.create_student(%{display_name: "新學生"})
    assert Sales.purchased_package_ids_for_student(student.id) == MapSet.new()
  end
end
