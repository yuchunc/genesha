defmodule Ganesha.Sales do
  @moduledoc """
  Purchases (the money side of a sale) and the payments settling them.

  A purchase has no month of its own. Its period is derived from the dates of
  the attendance rows that reference it, which is why there is no month column
  anywhere in this schema.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Repo
  alias Ganesha.Sales.Purchase

  def get_purchase!(id) do
    Purchase |> Repo.get!(id) |> Repo.preload([:student, :package, :slot])
  end

  def create_purchase(attrs) do
    %Purchase{} |> Purchase.changeset(attrs) |> Repo.insert()
  end

  def update_purchase(%Purchase{} = purchase, attrs) do
    purchase |> Purchase.changeset(attrs) |> Repo.update()
  end

  def change_purchase(%Purchase{} = purchase, attrs \\ %{}) do
    Purchase.changeset(purchase, attrs)
  end

  @doc """
  What the student owes for this purchase: the override when set, else list price.

  She records final agreed numbers rather than discounts, so the override is a
  plain replacement and no arithmetic has to stay consistent.
  """
  @spec payable(Purchase.t()) :: integer()
  def payable(%Purchase{custom_amount: nil, list_price: list_price}), do: list_price
  def payable(%Purchase{custom_amount: custom_amount}), do: custom_amount

  def list_purchases_for_student(student_id) do
    Repo.all(
      from p in Purchase,
        where: p.student_id == ^student_id,
        order_by: [desc: p.inserted_at],
        preload: [:package, :slot]
    )
  end

  alias Ganesha.Sales.Payment

  def record_payment(attrs) do
    %Payment{} |> Payment.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Confirms that the money actually arrived.

  Only ever called from a human action in the UI. No API in Taiwan can tell
  this application that a personal transfer landed, so this is an assertion by
  the teacher, and the schema records who made it.
  """
  def confirm_payment(%Payment{} = payment, confirmed_by) do
    payment |> Payment.confirmation_changeset(confirmed_by) |> Repo.update()
  end

  def list_payments_for_purchase(purchase_id) do
    Repo.all(from p in Payment, where: p.purchase_id == ^purchase_id, order_by: p.paid_on)
  end

  @doc """
  Whether a repeated 帳後五碼 looks like a mistake rather than a deliberate split.

  One bank transfer may be recorded as several payment rows, so a shared
  `reported_last5` is normal. It is only suspicious when the rows belong to
  different students, or when more than one row sits against the same purchase.
  """
  @spec suspicious_last5?(Payment.t()) :: boolean()
  def suspicious_last5?(%Payment{reported_last5: nil}), do: false

  def suspicious_last5?(%Payment{} = payment) do
    student_id =
      Repo.one!(from p in Purchase, where: p.id == ^payment.purchase_id, select: p.student_id)

    Repo.all(
      from pay in Payment,
        join: pur in Purchase,
        on: pur.id == pay.purchase_id,
        where: pay.reported_last5 == ^payment.reported_last5 and pay.id != ^payment.id,
        select: %{purchase_id: pay.purchase_id, student_id: pur.student_id}
    )
    |> Enum.any?(fn sibling ->
      sibling.student_id != student_id or sibling.purchase_id == payment.purchase_id
    end)
  end
end
