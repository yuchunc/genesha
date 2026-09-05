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

  @doc "How much was given away against list price. Negative means she charged more."
  @spec comped(Purchase.t()) :: integer()
  def comped(%Purchase{} = purchase), do: purchase.list_price - payable(purchase)

  def list_purchases_for_student(student_id) do
    Repo.all(
      from p in Purchase,
        where: p.student_id == ^student_id,
        order_by: [desc: p.inserted_at],
        preload: [:package, :slot]
    )
  end
end
