defmodule Ganesha.Repo.Migrations.CreateAssistantDigests do
  use Ecto.Migration

  def change do
    create table(:assistant_digests) do
      add :thread_id, references(:assistant_threads, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assistant_digests, [:thread_id, :kind, :period_start])
  end
end
