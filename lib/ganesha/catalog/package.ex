defmodule Ganesha.Catalog.Package do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(monthly drop_in trial)
  @grandfather_strategies ~w(none past_purchasers)

  schema "packages" do
    field :name, :string
    field :kind, :string
    field :price_per_class, :integer
    field :included_makeups, :integer, default: 0
    field :active, :boolean, default: true
    field :grandfather_strategy, :string, default: "none"

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def grandfather_strategies, do: @grandfather_strategies

  def changeset(package, attrs) do
    package
    |> cast(attrs, [
      :name,
      :kind,
      :price_per_class,
      :included_makeups,
      :active,
      :grandfather_strategy
    ])
    |> validate_required([
      :name,
      :kind,
      :price_per_class,
      :included_makeups,
      :active,
      :grandfather_strategy
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:grandfather_strategy, @grandfather_strategies)
    |> validate_number(:price_per_class, greater_than_or_equal_to: 0)
    |> validate_number(:included_makeups, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end
end
