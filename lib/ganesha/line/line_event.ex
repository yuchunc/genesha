defmodule Ganesha.Line.LineEvent do
  use Ecto.Schema
  import Ecto.Changeset

  schema "line_events" do
    field :webhook_event_id, :string
    field :source_type, :string
    field :source_id, :string
    field :raw_type, :string
    field :payload, :map
    field :processed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(line_event, attrs) do
    line_event
    |> cast(attrs, [:webhook_event_id, :source_type, :source_id, :raw_type, :payload])
    |> validate_required([:webhook_event_id, :raw_type, :payload])
    |> unique_constraint(:webhook_event_id)
  end
end
