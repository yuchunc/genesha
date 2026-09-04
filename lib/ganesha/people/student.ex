defmodule Ganesha.People.Student do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.StudentAlias

  schema "students" do
    field :display_name, :string
    field :line_user_id, :string
    field :active, :boolean, default: true

    has_many :aliases, StudentAlias

    timestamps(type: :utc_datetime)
  end

  def changeset(student, attrs) do
    student
    |> cast(attrs, [:display_name, :line_user_id, :active])
    |> validate_required([:display_name, :active])
    |> unique_constraint(:line_user_id)
  end
end
