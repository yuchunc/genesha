defmodule Ganesha.Roster.Attendance do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.Student
  alias Ganesha.Sales.Purchase
  alias Ganesha.Studio.Session

  @kinds ~w(enrolled makeup drop_in trial)
  @states ~w(expected no_show)

  schema "attendances" do
    field :kind, :string
    field :state, :string, default: "expected"
    field :note, :string
    field :credit_id, :integer

    belongs_to :session, Session
    belongs_to :student, Student
    belongs_to :purchase, Purchase

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def states, do: @states

  def changeset(attendance, attrs) do
    attendance
    |> cast(attrs, [:session_id, :student_id, :kind, :purchase_id, :credit_id, :state, :note])
    |> validate_required([:session_id, :student_id, :kind, :state])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:session_id, :student_id],
      name: "attendances_session_id_student_id_index"
    )
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:student_id)
    |> foreign_key_constraint(:purchase_id)
  end
end
