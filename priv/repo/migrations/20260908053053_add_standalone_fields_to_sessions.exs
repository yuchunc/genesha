defmodule Ganesha.Repo.Migrations.AddStandaloneFieldsToSessions do
  use Ecto.Migration

  # Ecto.Migration.execute/1 and `alter table` only queue commands on the
  # migration runner; they run after up/0 returns, so they cannot share a
  # pinned connection with each other. This rebuild needs slot_id's NOT NULL
  # dropped (SQLite has no ALTER COLUMN) while attendances/credits hold FK
  # references to sessions, so every statement here uses repo().query!/2
  # directly — a normal Repo call that runs immediately — inside
  # repo().checkout/1 + repo().transaction/1, so they all run in order on one
  # pinned connection.
  #
  # PRAGMA foreign_keys must run outside the transaction: SQLite ignores
  # foreign_keys=OFF inside BEGIN (see sqlite.org/lang_altertable.html §8).
  @disable_ddl_transaction true

  def up do
    repo().checkout(fn ->
      repo().query!("PRAGMA foreign_keys = OFF")

      repo().transaction(fn ->
        repo().query!("""
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

        repo().query!("""
        INSERT INTO "sessions__tmp" ("id", "slot_id", "date", "style", "state", "cancel_reason", "inserted_at", "updated_at")
        SELECT "id", "slot_id", "date", "style", "state", "cancel_reason", "inserted_at", "updated_at" FROM "sessions"
        """)

        repo().query!("DROP TABLE \"sessions\"")
        repo().query!("ALTER TABLE \"sessions__tmp\" RENAME TO \"sessions\"")
        repo().query!("CREATE UNIQUE INDEX \"sessions_slot_id_date_index\" ON \"sessions\" (\"slot_id\", \"date\")")
        repo().query!("CREATE INDEX \"sessions_date_index\" ON \"sessions\" (\"date\")")

        case repo().query!("PRAGMA foreign_key_check") do
          %{rows: []} -> :ok
          %{rows: violations} ->
            raise "foreign key violations after sessions rebuild: #{inspect(violations)}"
        end
      end)

      repo().query!("PRAGMA foreign_keys = ON")
    end)
  end

  def down do
    %{rows: [[count]]} =
      repo().query!("SELECT COUNT(*) FROM \"sessions\" WHERE \"slot_id\" IS NULL")

    if count > 0 do
      raise "cannot roll back: #{count} standalone session(s) exist and would be destroyed"
    end

    repo().checkout(fn ->
      repo().query!("PRAGMA foreign_keys = OFF")

      repo().transaction(fn ->
        repo().query!("""
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

        repo().query!("""
        INSERT INTO "sessions__tmp" ("id", "slot_id", "date", "style", "state", "cancel_reason", "inserted_at", "updated_at")
        SELECT "id", "slot_id", "date", "style", "state", "cancel_reason", "inserted_at", "updated_at" FROM "sessions"
        """)

        repo().query!("DROP TABLE \"sessions\"")
        repo().query!("ALTER TABLE \"sessions__tmp\" RENAME TO \"sessions\"")
        repo().query!("CREATE UNIQUE INDEX \"sessions_slot_id_date_index\" ON \"sessions\" (\"slot_id\", \"date\")")
        repo().query!("CREATE INDEX \"sessions_date_index\" ON \"sessions\" (\"date\")")

        case repo().query!("PRAGMA foreign_key_check") do
          %{rows: []} -> :ok
          %{rows: violations} ->
            raise "foreign key violations after sessions rebuild: #{inspect(violations)}"
        end
      end)

      repo().query!("PRAGMA foreign_keys = ON")
    end)
  end
end
