defmodule Ganesha.Assistant.Digest do
  @moduledoc """
  A daily or weekly summary of the Teacher chat (spec §5.2, §6.4). Only the
  Teacher chat has digests (ADR 0003).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.Thread

  @kinds ~w(daily weekly)

  schema "assistant_digests" do
    field :kind, :string
    field :period_start, :date
    field :period_end, :date
    field :content, :string

    belongs_to :thread, Thread

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(digest, attrs) do
    digest
    |> cast(attrs, [:thread_id, :kind, :period_start, :period_end, :content])
    |> validate_required([:thread_id, :kind, :period_start, :period_end, :content])
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:thread_id)
    |> unique_constraint([:thread_id, :kind, :period_start],
      name: "assistant_digests_thread_id_kind_period_start_index"
    )
  end
end
