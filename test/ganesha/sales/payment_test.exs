defmodule Ganesha.Sales.PaymentTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, Clock, People, Sales}

  defp purchase_fixture(student_name \\ nil) do
    name = student_name || "S#{System.unique_integer([:positive])}"
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "pkg-#{System.unique_integer([:positive])}",
        kind: "monthly",
        price_per_class: 400
      })

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    purchase
  end

  test "a recorded payment starts as a claim" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_pay",
        paid_on: Clock.today()
      })

    assert payment.state == "claimed"
    assert is_nil(payment.confirmed_at)
    assert is_nil(payment.confirmed_by)
  end

  test "record_payment/1 cannot be tricked into creating a confirmed payment" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: Clock.today(),
        state: "confirmed",
        confirmed_at: DateTime.utc_now(),
        confirmed_by: "sneaky"
      })

    assert payment.state == "claimed", "state must not be castable"
    assert is_nil(payment.confirmed_at)
    assert is_nil(payment.confirmed_by)
  end

  test "confirm_payment/2 stamps who confirmed it and when" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "line_bank",
        paid_on: Clock.today(),
        reported_last5: "12345"
      })

    assert {:ok, confirmed} = Sales.confirm_payment(payment, "teacher@example.com")
    assert confirmed.state == "confirmed"
    assert confirmed.confirmed_by == "teacher@example.com"
    refute is_nil(confirmed.confirmed_at)
  end

  test "confirm_payment/2 refuses an empty confirmer" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 100,
        method: "cash",
        paid_on: Clock.today()
      })

    assert {:error, cs} = Sales.confirm_payment(payment, "")
    assert "can't be blank" in errors_on(cs).confirmed_by
  end

  test "dispute_payment/2 records the reason" do
    purchase = purchase_fixture()

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 100,
        method: "cash",
        paid_on: Clock.today()
      })

    assert {:ok, disputed} = Sales.dispute_payment(payment, "銀行沒有這筆")
    assert disputed.state == "disputed"
    assert disputed.note == "銀行沒有這筆"
  end

  test "rejects an unknown method, a negative amount, and a bad last5" do
    purchase = purchase_fixture()
    base = %{purchase_id: purchase.id, paid_on: Clock.today()}

    assert {:error, cs} = Sales.record_payment(Map.merge(base, %{amount: 100, method: "bitcoin"}))
    assert "is invalid" in errors_on(cs).method

    assert {:error, cs} = Sales.record_payment(Map.merge(base, %{amount: -1, method: "cash"}))
    assert "must be greater than or equal to 0" in errors_on(cs).amount

    attrs = Map.merge(base, %{amount: 100, method: "cash", reported_last5: "abcde"})
    assert {:error, cs} = Sales.record_payment(attrs)
    assert "must be up to five digits" in errors_on(cs).reported_last5
  end

  describe "suspicious_last5?/1 — split-aware duplicate detection" do
    test "same student, same day, different purchases is a split and not suspicious" do
      {:ok, student} = People.create_student(%{display_name: "彩華"})

      {:ok, pkg} =
        Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

      {:ok, mon} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 800})

      {:ok, wed} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1200})

      today = Clock.today()

      {:ok, _first} =
        Sales.record_payment(%{
          purchase_id: mon.id,
          amount: 800,
          method: "line_pay",
          paid_on: today,
          reported_last5: "54321"
        })

      {:ok, second} =
        Sales.record_payment(%{
          purchase_id: wed.id,
          amount: 1200,
          method: "line_pay",
          paid_on: today,
          reported_last5: "54321"
        })

      refute Sales.suspicious_last5?(second)
    end

    test "two rows against the same purchase sharing a last5 is suspicious" do
      purchase = purchase_fixture()
      today = Clock.today()

      {:ok, _} =
        Sales.record_payment(%{
          purchase_id: purchase.id,
          amount: 1600,
          method: "line_pay",
          paid_on: today,
          reported_last5: "99999"
        })

      {:ok, dup} =
        Sales.record_payment(%{
          purchase_id: purchase.id,
          amount: 1600,
          method: "line_pay",
          paid_on: today,
          reported_last5: "99999"
        })

      assert Sales.suspicious_last5?(dup)
    end

    test "the same last5 from a different student is suspicious" do
      a = purchase_fixture("A")
      b = purchase_fixture("B")
      today = Clock.today()

      {:ok, _} =
        Sales.record_payment(%{
          purchase_id: a.id,
          amount: 400,
          method: "line_pay",
          paid_on: today,
          reported_last5: "11111"
        })

      {:ok, other} =
        Sales.record_payment(%{
          purchase_id: b.id,
          amount: 400,
          method: "line_pay",
          paid_on: today,
          reported_last5: "11111"
        })

      assert Sales.suspicious_last5?(other)
    end

    test "a payment with no reported last5 is never suspicious" do
      purchase = purchase_fixture()

      {:ok, payment} =
        Sales.record_payment(%{
          purchase_id: purchase.id,
          amount: 400,
          method: "cash",
          paid_on: Clock.today()
        })

      refute Sales.suspicious_last5?(payment)
    end
  end
end
