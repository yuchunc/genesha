defmodule Ganesha.Assistant.Tasks.ConfirmPaymentTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Tasks.ConfirmPayment

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 1600})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 800,
        method: "line_pay",
        paid_on: ~D[2026-10-02],
        source: "manual"
      })

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      payment: payment
    }
  end

  describe "propose/2" do
    test "captures the claimed payment", c do
      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      assert student_id == c.student.id
      assert parsed["amount"] == 800
      assert parsed["before_state"] == "claimed"
      assert c.payment.state == "claimed"
    end

    test "rejects a confirmed payment", c do
      {:ok, _} = Sales.confirm_payment(c.payment, "teacher@example.com")

      assert {:error, message} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)
      assert message =~ "confirmed"
    end
  end

  describe "apply/2" do
    test "confirms the payment", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      assert {:ok, {"Ganesha.Sales.Payment", payment_id}} =
               ConfirmPayment.apply(parsed, "line:teacher")

      assert Sales.get_payment(payment_id).state == "confirmed"
    end

    test "fails if the payment was confirmed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)
      {:ok, _} = Sales.confirm_payment(c.payment, "teacher@example.com")

      assert {:error, :payment_not_claimed} = ConfirmPayment.apply(parsed, "line:teacher")
    end
  end

  describe "describe/2" do
    test "shows the state change", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      assert %{changes: [{"狀態", "待確認", "已確認"}]} = ConfirmPayment.describe(parsed, "zh-TW")
    end
  end

  describe "summary/2" do
    test "names the student, amount, method and date", c do
      {:ok, %{parsed: parsed}} = ConfirmPayment.propose(%{"payment_id" => c.payment.id}, c.ctx)

      for locale <- ["zh-TW", "en"] do
        text = ConfirmPayment.summary(parsed, locale)
        assert text =~ "Lulu"
        assert text =~ "NT$800"
        assert text =~ "LINE Pay"
        assert text =~ "10/2"
      end
    end
  end
end
