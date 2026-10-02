defmodule Ganesha.Repo.Migrations.ExtendDraftsForTasks do
  use Ecto.Migration

  def up do
    alter table(:drafts) do
      add :failure_reason, :string
      add :replaced_by_id, references(:drafts, on_delete: :nilify_all)
      add :notified_at, :utc_datetime
    end

    create index(:drafts, [:state, :thread_id])

    # Spec §5.1: a Draft's kind is now its task's name. Applied and discarded
    # rows of retired kinds keep their old kind as history; pending ones can no
    # longer be applied, so they are discarded.
    execute "UPDATE drafts SET kind = 'record_payment' WHERE kind = 'payment'"

    execute "UPDATE drafts SET state = 'discarded' " <>
              "WHERE state = 'pending' AND kind IN ('attendance', 'unknown')"
  end

  # Pending attendance/unknown Drafts discarded by `up/0` stay discarded.
  def down do
    execute "UPDATE drafts SET kind = 'payment' WHERE kind = 'record_payment'"

    drop index(:drafts, [:state, :thread_id])

    alter table(:drafts) do
      remove :notified_at
      remove :replaced_by_id
      remove :failure_reason
    end
  end
end
