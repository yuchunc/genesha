defmodule Ganesha.People.LineMember do
  @moduledoc """
  A LINE group member who is not (yet) a Student (spec
  2026-10-19-november-launch-design.md §1). `not_student` is the teacher's
  answer; `unsure` is an open question. Linking or creating a Student from an
  `unsure` row deletes it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(not_student unsure)

  schema "line_members" do
    field :line_user_id, :string
    field :display_name, :string
    field :state, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def changeset(line_member, attrs) do
    line_member
    |> cast(attrs, [:line_user_id, :display_name, :state])
    |> validate_required([:line_user_id, :display_name, :state])
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:line_user_id)
  end
end
