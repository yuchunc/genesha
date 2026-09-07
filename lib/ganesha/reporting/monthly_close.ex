defmodule Ganesha.Reporting.MonthlyClose do
  @moduledoc """
  A month's confirmed revenue, frozen once that month has ended.

  One row per month. `revenue` and `revenue_by_method` are snapshots taken
  at close time (or refreshed by a later confirmation landing in an
  already-closed month) — never recomputed on read.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "monthly_closes" do
    field :month, :date
    field :revenue, :integer
    field :revenue_by_method, :map
    field :tax_threshold, :integer

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(monthly_close, attrs) do
    monthly_close
    |> cast(attrs, [:month, :revenue, :revenue_by_method, :tax_threshold])
    |> validate_required([:month, :revenue, :revenue_by_method, :tax_threshold])
    |> unique_constraint(:month)
  end
end
