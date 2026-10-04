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

  describe "summary/2" do
    @summary_parsed %{
      "student_name" => "Amy",
      "amount" => 3200,
      "method" => "line_pay",
      "paid_on" => "2026-10-03",
      "before_owed" => 3200
    }

    test "names who paid, how much, how, when, and what is still owed" do
      for locale <- ["zh-TW", "en"] do
        text = RecordPayment.summary(@summary_parsed, locale)
        assert text =~ "Amy"
        assert text =~ "NT$3,200"
        assert text =~ "LINE Pay"
        assert text =~ "10/3"
        assert text =~ "→ NT$0"
        refute text =~ "%{"
      end
    end

    test "leaves the owed part out when nothing was owed before" do
      text = RecordPayment.summary(%{@summary_parsed | "before_owed" => nil}, "zh-TW")
      refute text =~ "→"
    end
  end
end
