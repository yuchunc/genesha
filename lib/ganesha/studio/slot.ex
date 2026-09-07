defmodule Ganesha.Studio.Slot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "slots" do
    field :weekday, :integer
    field :start_time, :time
    field :end_time, :time
    field :default_style, :string
    field :label, :string
    field :active, :boolean, default: true

    has_many :sessions, Ganesha.Studio.Session

    timestamps(type: :utc_datetime)
  end

  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:weekday, :start_time, :end_time, :default_style, :label, :active])
    |> validate_required([:weekday, :start_time, :end_time, :default_style, :label, :active])
    |> validate_inclusion(:weekday, 1..7)
    |> unique_constraint([:weekday, :start_time], name: "slots_weekday_start_time_index")
  end
end
