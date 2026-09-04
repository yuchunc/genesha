defmodule Ganesha.Repo.Migrations.CreateStudents do
  use Ecto.Migration

  def change do
    create table(:students) do
      add :display_name, :string, null: false
      # Nullable: a cash-only student may never appear in LINE. Unique because
      # a LINE user id is stable for the life of the account, and is the key we
      # match on once known. Display names change freely and are never the key.
      add :line_user_id, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:students, [:line_user_id])

    create table(:student_aliases) do
      add :student_id, references(:students, on_delete: :delete_all), null: false
      add :alias, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # An alias must identify exactly one student, or the phase-2 parser cannot
    # use it to attribute a message.
    create unique_index(:student_aliases, [:alias])
    create index(:student_aliases, [:student_id])
  end
end
