defmodule Ganesha.Assistant.Tasks.MonthMoneyTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.MonthMoney

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, package} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}, package: package}
  end

  defp purchase(package, name, list_price) do
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: package.id,
        list_price: list_price
      })

    {student, purchase}
  end

  defp pay(purchase, amount, paid_on, confirm? \\ true) do
    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: amount,
        method: "cash",
        paid_on: paid_on
      })

    if confirm?, do: {:ok, _} = Sales.confirm_payment(payment, "teacher")
  end

  defp ledger(package) do
    {lulu, lulus} = purchase(package, "Lulu", 1600)
    pay(lulus, 400, ~D[2026-10-01])
    pay(lulus, 300, ~D[2026-09-15])
    pay(lulus, 500, ~D[2026-10-02], false)

    {amy, _} = purchase(package, "Amy", 700)

    {bea, beas} = purchase(package, "Bea", 400)
    pay(beas, 400, ~D[2026-10-02])

    %{lulu: lulu, amy: amy, bea: bea}
  end

  defp opens?(data, month, revenue),
    do: String.starts_with?(data, "#{Format.month_title(month, "zh-TW")}: revenue #{revenue}, ")

  test "defaults to today's month: confirmed revenue and everyone who owes", c do
    s = ledger(c.package)

    assert {:ok, %{data: data} = answer} = MonthMoney.answer(%{}, c.ctx)

    refute Map.has_key?(answer, :card)
    assert opens?(data, ~D[2026-10-01], Format.money(800))
    refute data =~ "close to it"
    assert data =~ "2 student(s) owe #{Format.money(1600)}"
    assert data =~ ~r/student #{s.lulu.id}\b[^;,]*#{Regex.escape(Format.money(900))}/
    assert data =~ ~r/student #{s.amy.id}\b[^;,]*#{Regex.escape(Format.money(700))}/
    refute data =~ ~r/student #{s.bea.id}\b/
  end

  test "a date inside another month reports that month's revenue", c do
    ledger(c.package)

    assert {:ok, %{data: data}} = MonthMoney.answer(%{"month" => "2026-09-20"}, c.ctx)

    assert opens?(data, ~D[2026-09-01], Format.money(300))
  end

  test "warns once the month nears the tax threshold and reports how far along it is", c do
    {_dan, dans} = purchase(c.package, "Dan", 45_000)
    pay(dans, 45_000, ~D[2026-10-02])

    assert {:ok, %{data: data}} = MonthMoney.answer(%{}, c.ctx)

    assert opens?(data, ~D[2026-10-01], Format.money(45_000))

    assert data =~
             ~r/\b90% of the #{Regex.escape(Format.money(50_000))} tax threshold \(close to it\)/

    assert data =~ "Nobody owes money"
  end

  test "reports tax progress below the warning line too", c do
    ledger(c.package)

    assert {:ok, %{data: data}} = MonthMoney.answer(%{}, c.ctx)

    # NT$800 of NT$50,000 rounds to 2%.
    assert data =~ ~r/\b2% of the #{Regex.escape(Format.money(50_000))} tax threshold/
  end

  test "answers a month with no money and nobody owing", c do
    assert {:ok, %{data: data}} = MonthMoney.answer(%{}, c.ctx)

    assert opens?(data, ~D[2026-10-01], Format.money(0))
    assert data =~ "Nobody owes money"
    refute data =~ "student"
  end

  test "rejects a month that is not an ISO 8601 date", c do
    assert {:error, _} = MonthMoney.answer(%{"month" => "October"}, c.ctx)
    assert {:error, _} = MonthMoney.answer(%{"month" => 10}, c.ctx)
  end
end
