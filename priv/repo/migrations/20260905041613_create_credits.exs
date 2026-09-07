defmodule Ganesha.Repo.Migrations.CreateCredits do
  use Ecto.Migration

  def change do
    create table(:credits) do
      add :student_id, references(:students, on_delete: :restrict), null: false
      add :source, :string, null: false
      # Ordinal within one purchase's grant, so re-running minting collides on
      # the partial unique index below rather than duplicating credits.
      add :seq, :integer
      add :origin_purchase_id, references(:purchases, on_delete: :restrict)
      add :origin_session_id, references(:sessions, on_delete: :restrict)
      # NULL means it never expires, which is the case for a cancellation credit.
      # July's 颱風假 credits were still being spent in August.
      add :expires_on, :date
      add :consumed_by_attendance_id, references(:attendances, on_delete: :restrict)
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:credits, [:student_id])
    create index(:credits, [:consumed_by_attendance_id])

    # SQLite supports partial indexes, and cannot ALTER TABLE ADD CONSTRAINT,
    # so these are where idempotency is actually guaranteed rather than merely
    # attempted in application code.
    create unique_index(:credits, [:origin_purchase_id, :seq],
             where: "source = 'package'",
             name: "credits_package_grant_index"
           )

    create unique_index(:credits, [:origin_session_id, :student_id],
             where: "source = 'cancellation'",
             name: "credits_cancellation_grant_index"
           )
  end
end
