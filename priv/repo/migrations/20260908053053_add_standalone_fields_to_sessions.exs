defmodule Ganesha.Repo.Migrations.AddStandaloneFieldsToSessions do
  use Ecto.Migration

  # SQLite cannot toggle foreign_keys mid-DDL-transaction, and defer_foreign_keys
  # still fails COMMIT when child tables (attendances/credits) reference sessions
  # during a DROP TABLE rebuild. Pin one connection and disable FK checks around a
  # manual transaction instead of relying on Ecto's DDL transaction wrapper.
  @disable_ddl_transaction true

  def up do
    repo().checkout(fn ->
      execute("PRAGMA foreign_keys = OFF")

      repo().transaction(fn ->
            alter table(:sessions) do
              add :label, :string
              add :start_time, :time
              add :end_time, :time
            end

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

            execute(
              "CREATE UNIQUE INDEX \"sessions_slot_id_date_index\" ON \"sessions\" (\"slot_id\", \"date\")"
            )

            execute("CREATE INDEX \"sessions_date_index\" ON \"sessions\" (\"date\")")
      end)

      execute("PRAGMA foreign_keys = ON")
    end)
  end

  def down do
    %{rows: [[count]]} =
      repo().query!("SELECT COUNT(*) FROM \"sessions\" WHERE \"slot_id\" IS NULL")

    if count > 0 do
      raise "cannot roll back: #{count} standalone session(s) exist and would be destroyed"
    end

    repo().checkout(fn ->
      execute("PRAGMA foreign_keys = OFF")

      repo().transaction(fn ->
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

            execute(
              "CREATE UNIQUE INDEX \"sessions_slot_id_date_index\" ON \"sessions\" (\"slot_id\", \"date\")"
            )

            execute("CREATE INDEX \"sessions_date_index\" ON \"sessions\" (\"date\")")
      end)

      execute("PRAGMA foreign_keys = ON")
    end)
  end
end
