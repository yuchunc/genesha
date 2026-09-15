defmodule Ganesha.Repo.Migrations.CreateDrafts do
  use Ecto.Migration

  def change do
    create table(:drafts) do
      add :thread_id, references(:assistant_threads, on_delete: :delete_all), null: false
      add :origin_message_id, references(:assistant_messages, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :student_id, references(:students, on_delete: :nilify_all)
      add :parsed, :map, null: false
      add :confidence, :float, null: false, default: 1.0
      add :state, :string, null: false, default: "pending"
      add :applied_record_type, :string
      add :applied_record_id, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:drafts, [:thread_id, :state])
    create index(:drafts, [:origin_message_id])
  end
end
