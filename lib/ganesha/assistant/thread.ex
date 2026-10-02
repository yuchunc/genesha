defmodule Ganesha.Assistant.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @source_types ~w(group teacher user)

  schema "assistant_threads" do
    field :source_type, :string
    field :source_id, :string
    field :locale, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def source_types, do: @source_types

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:source_type, :source_id, :locale])
    |> validate_required([:source_type, :source_id])
    |> validate_inclusion(:source_type, @source_types)
    |> unique_constraint([:source_type, :source_id],
      name: "assistant_threads_source_type_source_id_index"
    )
  end
end
