defmodule Ganesha.Sales.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Sales.Purchase

  @methods ~w(line_pay line_bank cash other)
  @sources ~w(manual line_draft)
  @states ~w(claimed confirmed disputed)

  schema "payments" do
    field :amount, :integer
    field :method, :string
    field :state, :string, default: "claimed"
    field :paid_on, :date
    field :reported_last5, :string
    field :source, :string, default: "manual"
    field :note, :string
    field :confirmed_at, :utc_datetime
    field :confirmed_by, :string

    belongs_to :purchase, Purchase

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def methods, do: @methods
  def sources, do: @sources
  def states, do: @states

  @doc """
  Recording a payment.

  `state`, `confirmed_at` and `confirmed_by` are deliberately absent from
  `cast/3`: a payment may only become confirmed through
  `confirmation_changeset/2`, which demands a human identity. The trust
  boundary is enforced by the shape of this function, not by a comment.
  """
  def changeset(payment, attrs) do
    payment
    |> cast(attrs, [:purchase_id, :amount, :method, :paid_on, :reported_last5, :source, :note])
    |> validate_required([:purchase_id, :amount, :method, :paid_on])
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> validate_inclusion(:method, @methods)
    |> validate_inclusion(:source, @sources)
    |> validate_format(:reported_last5, ~r/^\d{1,5}$/, message: "must be up to five digits")
    |> put_change(:state, "claimed")
    |> foreign_key_constraint(:purchase_id)
  end

  @doc "The only path to a confirmed payment. Requires who confirmed it."
  def confirmation_changeset(payment, confirmed_by) do
    payment
    |> cast(%{confirmed_by: confirmed_by}, [:confirmed_by])
    |> validate_required([:confirmed_by])
    |> put_change(:state, "confirmed")
    |> put_change(:confirmed_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def dispute_changeset(payment, reason) do
    payment
    |> cast(%{note: reason}, [:note])
    |> put_change(:state, "disputed")
  end
end
