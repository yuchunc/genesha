defmodule Ganesha.People.StudentAlias do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.Student

  schema "student_aliases" do
    field :alias, :string
    belongs_to :student, Student

    timestamps(type: :utc_datetime)
  end

  def changeset(student_alias, attrs) do
    student_alias
    |> cast(attrs, [:alias, :student_id])
    |> validate_required([:alias, :student_id])
    |> unique_constraint(:alias)
  end
end
