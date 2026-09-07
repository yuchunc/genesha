defmodule Ganesha.Sales.Purchase do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Catalog.Package
  alias Ganesha.People.Student
  alias Ganesha.Studio.Slot

  schema "purchases" do
    field :list_price, :integer
    field :custom_amount, :integer
    field :note, :string

    belongs_to :student, Student
    belongs_to :package, Package
    belongs_to :slot, Slot

    timestamps(type: :utc_datetime)
  end

  def changeset(purchase, attrs) do
    purchase
    |> cast(attrs, [:student_id, :package_id, :slot_id, :list_price, :custom_amount, :note])
    |> validate_required([:student_id, :package_id, :list_price])
    |> validate_number(:list_price, greater_than_or_equal_to: 0)
    |> validate_number(:custom_amount, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:student_id)
    |> foreign_key_constraint(:package_id)
    |> foreign_key_constraint(:slot_id)
  end
end
