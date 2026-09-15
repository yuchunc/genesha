defmodule Ganesha.Repo.Migrations.CreateLineEvents do
  use Ecto.Migration

  def change do
    create table(:line_events) do
      add :webhook_event_id, :string, null: false
      add :source_type, :string
      add :source_id, :string
      add :raw_type, :string, null: false
      add :payload, :map, null: false
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:line_events, [:webhook_event_id])
  end
end
