defmodule Ganesha.Repo.Migrations.AddStandaloneFieldsToSessions do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    alter table(:sessions) do
      add :label, :string
      add :start_time, :time
      add :end_time, :time
    end

    # SQLite cannot ALTER COLUMN to drop NOT NULL on slot_id; rebuild the table.
    execute("PRAGMA foreign_keys = OFF")

    execute("""
    CREATE TABLE "sessions__tmp" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "slot_id" INTEGER CONSTRAINT "sessions_slot_id_fkey" REFERENCES "slots"("id") ON DELETE RESTRICT,
      "date" TEXT NOT NULL,
      "style" TEXT NOT NULL,
      "state" TEXT DEFAULT 'scheduled' NOT NULL,
      "cancel_reason" TEXT,
      "label" TEXT,
      "start_time" TEXT,
      "end_time" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO "sessions__tmp" ("id", "slot_id", "date", "style", "state", "cancel_reason", "label", "start_time", "end_time", "inserted_at", "updated_at")
    SELECT "id", "slot_id", "date", "style", "state", "cancel_reason", "label", "start_time", "end_time", "inserted_at", "updated_at" FROM "sessions"
    """)

    execute("DROP TABLE \"sessions\"")
    execute("ALTER TABLE \"sessions__tmp\" RENAME TO \"sessions\"")

    execute("CREATE UNIQUE INDEX \"sessions_slot_id_date_index\" ON \"sessions\" (\"slot_id\", \"date\")")
    execute("CREATE INDEX \"sessions_date_index\" ON \"sessions\" (\"date\")")

    execute("PRAGMA foreign_keys = ON")
  end

  def down do
    %{rows: [[count]]} =
      repo().query!("SELECT COUNT(*) FROM \"sessions\" WHERE \"slot_id\" IS NULL")

    if count > 0 do
      raise "cannot roll back: #{count} standalone session(s) exist and would be destroyed"
    end

    execute("PRAGMA foreign_keys = OFF")

    execute("""
    CREATE TABLE "sessions__tmp" (
      "id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "slot_id" INTEGER NOT NULL CONSTRAINT "sessions_slot_id_fkey" REFERENCES "slots"("id") ON DELETE RESTRICT,
      "date" TEXT NOT NULL,
      "style" TEXT NOT NULL,
      "state" TEXT DEFAULT 'scheduled' NOT NULL,
      "cancel_reason" TEXT,
      "inserted_at" TEXT NOT NULL,
      "updated_at" TEXT NOT NULL
    )
    """)

    execute("""
    INSERT INTO "sessions__tmp" ("id", "slot_id", "date", "style", "state", "cancel_reason", "inserted_at", "updated_at")
    SELECT "id", "slot_id", "date", "style", "state", "cancel_reason", "inserted_at", "updated_at" FROM "sessions" WHERE "slot_id" IS NOT NULL
    """)

    execute("DROP TABLE \"sessions\"")
    execute("ALTER TABLE \"sessions__tmp\" RENAME TO \"sessions\"")

    execute("CREATE UNIQUE INDEX \"sessions_slot_id_date_index\" ON \"sessions\" (\"slot_id\", \"date\")")
    execute("CREATE INDEX \"sessions_date_index\" ON \"sessions\" (\"date\")")

    execute("PRAGMA foreign_keys = ON")
  end
end
