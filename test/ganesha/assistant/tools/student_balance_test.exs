defmodule Ganesha.Assistant.Tools.StudentBalanceTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.StudentBalance
  alias Ganesha.{Catalog, People, Sales}

  test "reports outstanding balance for a student" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        list_price: 400
      })

    {content, draft_id} = StudentBalance.call(%{"student_id" => student.id}, nil)
    assert draft_id == nil
    assert %{"student_id" => id, "outstanding" => 400} = Jason.decode!(content)
    assert id == student.id
  end

  test "reports missing student" do
    {content, nil} = StudentBalance.call(%{"student_id" => 999_999}, nil)
    assert content == "no student found matching 999999"
  end
end
