defmodule Ganesha.Roster.Credit do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.People.Student
  alias Ganesha.Roster.Attendance
  alias Ganesha.Sales.Purchase
  alias Ganesha.Studio.Session

  @sources ~w(package cancellation)

  schema "credits" do
    field :source, :string
    field :seq, :integer
    field :expires_on, :date
    field :note, :string

    belongs_to :student, Student
    belongs_to :origin_purchase, Purchase
    belongs_to :origin_session, Session
    belongs_to :consumed_by_attendance, Attendance

    timestamps(type: :utc_datetime)
  end

  def sources, do: @sources

  def changeset(credit, attrs) do
    credit
    |> cast(attrs, [
      :student_id,
      :source,
      :seq,
      :origin_purchase_id,
      :origin_session_id,
      :expires_on,
      :consumed_by_attendance_id,
      :note
    ])
    |> validate_required([:student_id, :source])
    |> validate_inclusion(:source, @sources)
    # Ecto SQLite3's driver reports raw UNIQUE-violation errors by column
    # list, not by the index's own name (`ecto_sqlite3` has no way to read it
    # back from SQLite), so it recovers a constraint identifier using its own
    # `<table>_<col>_<col>_index` convention regardless of what the migration
    # named the index. These `name:` values are written to match that
    # convention so `Repo.insert` returns a changeset error instead of
    # raising `Ecto.ConstraintError`; the actual uniqueness is still enforced
    # by the partial unique indexes created in the migration.
    |> unique_constraint([:origin_purchase_id, :seq],
      name: "credits_origin_purchase_id_seq_index"
    )
    |> unique_constraint([:origin_session_id, :student_id],
      name: "credits_origin_session_id_student_id_index"
    )
  end

  @doc "Marks the credit spent by a specific makeup attendance."
  def consumption_changeset(credit, %Attendance{} = attendance) do
    change(credit, %{consumed_by_attendance_id: attendance.id})
  end
end
