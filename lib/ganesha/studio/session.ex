defmodule Ganesha.Studio.Session do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Studio.Slot

  @states ~w(scheduled cancelled)

  schema "sessions" do
    field :date, :date
    field :style, :string
    field :state, :string, default: "scheduled"
    field :cancel_reason, :string

    belongs_to :slot, Slot

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:slot_id, :date, :style, :state, :cancel_reason])
    |> validate_required([:slot_id, :date, :style, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:slot_id, :date], name: "sessions_slot_id_date_index")
    |> foreign_key_constraint(:slot_id)
  end

  @doc "Cancellation always carries a reason; it is shown to students in the roster."
  def cancellation_changeset(session, reason) do
    session
    |> cast(%{cancel_reason: reason}, [:cancel_reason])
    |> put_change(:state, "cancelled")
    |> validate_required([:cancel_reason])
  end
end
