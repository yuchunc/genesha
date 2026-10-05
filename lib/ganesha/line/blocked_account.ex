defmodule Ganesha.Line.BlockedAccount do
  @moduledoc """
  A LINE group, or a group sender, the assistant ignores (spec
  2026-10-05-line-group-blocklist-design.md §1). A blocked sender is ignored
  in every group. Unblocking deletes the row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(group sender)

  schema "blocked_accounts" do
    field :kind, :string
    field :line_id, :string
    field :label, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(blocked_account, attrs) do
    blocked_account
    |> cast(attrs, [:kind, :line_id, :label])
    |> validate_required([:kind, :line_id, :label])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:kind, :line_id])
  end
end
