defmodule Ganesha.Reporting.CloseMonthWorkerTest do
  use Ganesha.DataCase
  use Oban.Testing, repo: Ganesha.Repo, engine: Oban.Engines.Lite

  alias Ganesha.{Catalog, Clock, People, Repo, Reporting, Sales}
  alias Ganesha.Reporting.CloseMonthWorker

  defp last_month, do: Date.shift(Date.beginning_of_month(Clock.today()), month: -1)

  test "closes the most recently elapsed month" do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, pkg} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 1600})

    {:ok, payment} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 1600,
        method: "cash",
        paid_on: last_month()
      })

    {:ok, _} = Sales.confirm_payment(payment, "teacher@example.com")

    assert :ok = perform_job(CloseMonthWorker, %{})

    closed = Reporting.get_closed_month(last_month())
    assert closed.revenue == 1600
  end

  test "is a no-op when the month is already closed" do
    {:ok, closed} = Reporting.close_month(last_month())

    # Overwrite the frozen row directly, bypassing Sales entirely, to a value
    # live computation would not currently reproduce. If the worker's
    # idempotency guard were bypassed, close_month/1 would recompute this
    # month from its (empty) payment data and clobber it back to 0.
    closed |> Ecto.Changeset.change(revenue: 9999) |> Repo.update!()

    assert :ok = perform_job(CloseMonthWorker, %{})

    assert Reporting.get_closed_month(last_month()).revenue == 9999
  end
end
