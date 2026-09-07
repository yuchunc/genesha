defmodule Ganesha.Repo.Migrations.CreateAttendances do
  use Ecto.Migration

  def change do
    create table(:attendances) do
      add :session_id, references(:sessions, on_delete: :restrict), null: false
      add :student_id, references(:students, on_delete: :restrict), null: false
      add :kind, :string, null: false
      # NULL for a makeup: there is no sale behind it, a credit pays for it.
      # 允一's "無費用，補颱風假" row is exactly this shape.
      add :purchase_id, references(:purchases, on_delete: :restrict)
      # Plain integer, not a reference: the credits table is created in Task 9,
      # and SQLite cannot add a foreign key to an existing table afterwards.
      add :credit_id, :integer
      add :state, :string, null: false, default: "expected"
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:attendances, [:session_id, :student_id])
    create index(:attendances, [:purchase_id])
    create index(:attendances, [:student_id])
  end
end
