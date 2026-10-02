defmodule Ganesha.Assistant.Tasks.RecordPaymentTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Sales}
  alias Ganesha.Assistant.Tasks.RecordPayment
  alias Ganesha.Sales.Payment

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, package} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 1600})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      package: package,
      purchase: purchase
    }
  end

  defp input(student, extra \\ %{}) do
    Map.merge(%{"student_id" => student.id, "amount" => 1600, "method" => "line_pay"}, extra)
  end

  describe "propose/2" do
    test "resolves the one purchase she owes on and captures what was owed before", c do
      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               RecordPayment.propose(input(c.student), c.ctx)

      assert student_id == c.student.id
      assert parsed["purchase_id"] == c.purchase.id
      assert parsed["amount"] == 1600
      assert parsed["paid_on"] == "2026-10-02"
      assert parsed["before_owed"] == 1600
      assert parsed["student_name"] == "Lulu"
      assert parsed["package_name"] == "月課程"
      assert Repo.aggregate(Payment, :count) == 0
    end

    test "asks for purchase_id when she owes on several purchases", c do
      {:ok, _} =
        Sales.create_purchase(%{
          student_id: c.student.id,
          package_id: c.package.id,
          list_price: 400
        })

      assert {:error, message} = RecordPayment.propose(input(c.student), c.ctx)
      assert message =~ "several purchases"
      assert message =~ "purchase #{c.purchase.id}"
    end

    test "takes an explicit purchase_id only if it is hers", c do
      {:ok, amy} = People.create_student(%{display_name: "Amy"})

      {:ok, amys} =
        Sales.create_purchase(%{student_id: amy.id, package_id: c.package.id, list_price: 400})

      assert {:error, message} =
               RecordPayment.propose(input(c.student, %{"purchase_id" => amys.id}), c.ctx)

      assert message =~ "not one of Lulu's purchases"
    end

    test "rejects an unknown student", c do
      assert {:error, message} =
               RecordPayment.propose(
                 %{"student_id" => -1, "amount" => 1, "method" => "cash"},
                 c.ctx
               )

      assert message =~ "no student with id -1"
    end

    test "rejects what the payment rules reject", c do
      assert {:error, message} =
               RecordPayment.propose(input(c.student, %{"method" => "bitcoin"}), c.ctx)

      assert message =~ "method: is invalid"

      assert {:error, message} =
               RecordPayment.propose(input(c.student, %{"reported_last5" => "abc"}), c.ctx)

      assert message =~ "reported_last5: must be up to five digits"
    end
  end

  describe "apply/2" do
    test "records the payment and confirms it as the teacher", c do
      {:ok, %{parsed: parsed}} = RecordPayment.propose(input(c.student), c.ctx)

      assert {:ok, {"Ganesha.Sales.Payment", id}} = RecordPayment.apply(parsed, "line:teacher")

      payment = Repo.get!(Payment, id)
      assert payment.state == "confirmed"
      assert payment.confirmed_by == "line:teacher"
      assert payment.source == "line_draft"
      assert payment.amount == 1600
      assert payment.paid_on == ~D[2026-10-02]
    end

    test "uses only the keys propose/2 wrote", c do
      {:ok, %{parsed: parsed}} = RecordPayment.propose(input(c.student), c.ctx)
      tampered = Map.merge(parsed, %{"source" => "manual", "state" => "disputed"})

      assert {:ok, {_type, id}} = RecordPayment.apply(tampered, "line:teacher")

      payment = Repo.get!(Payment, id)
      assert payment.source == "line_draft"
      assert payment.state == "confirmed"
    end

    test "fails without a purchase instead of guessing" do
      assert {:error, :missing_purchase_id} =
               RecordPayment.apply(%{"amount" => 400, "method" => "cash"}, "line:teacher")

      assert Repo.aggregate(Payment, :count) == 0
    end

    test "returns the changeset when the payment rules reject it", c do
      assert {:error, %Ecto.Changeset{}} =
               RecordPayment.apply(
                 %{"purchase_id" => c.purchase.id, "amount" => -5, "method" => "cash"},
                 "line:teacher"
               )
    end
  end

  describe "describe/2" do
    @parsed %{
      "student_id" => 7,
      "student_name" => "Lulu",
      "purchase_id" => 3,
      "amount" => 1600,
      "method" => "line_pay",
      "paid_on" => "2026-10-02",
      "reported_last5" => "12345",
      "package_name" => "月課程",
      "before_owed" => 1600
    }

    test "is built from parsed only and shows what is owed before → after" do
      assert %{
               title: "收款 Lulu NT$1,600",
               lines: ["方案：月課程", "付款方式：Line Pay", "付款日：10月2日", "末五碼：12345"],
               changes: [{"尚欠", "NT$1,600", "NT$0"}],
               web_path: "/students/7"
             } = RecordPayment.describe(@parsed, "zh-TW")
    end

    test "speaks English when the chat does" do
      assert %{
               title: "Payment Lulu NT$1,600",
               lines: [
                 "Package: 月課程",
                 "Method: LINE Pay",
                 "Paid on: 2026-10-02",
                 "Last 5 digits: 12345"
               ],
               changes: [{"Owed", "NT$1,600", "NT$0"}]
             } = RecordPayment.describe(@parsed, "en")
    end
  end
end
