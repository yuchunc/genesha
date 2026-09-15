defmodule Ganesha.Repo.Migrations.CreateAssistantThreads do
  use Ecto.Migration

  def change do
    create table(:assistant_threads) do
      add :source_type, :string, null: false
      add :source_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assistant_threads, [:source_type, :source_id])
  end
end
