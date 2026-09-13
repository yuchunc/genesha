defmodule Ganesha.Assistant.Tools.StudentHistoryTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.StudentHistory
  alias Ganesha.{Catalog, People, Sales}

  test "summarizes a student's purchases" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, _} = Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

    {content, draft_id} = StudentHistory.call(%{"student_id" => student.id}, nil)
    assert draft_id == nil
    assert %{"purchases" => [%{"list_price" => 400}], "attendances" => []} = Jason.decode!(content)
  end
end
