defmodule Ganesha.Repo.Migrations.CreateAssistantMessages do
  use Ecto.Migration

  def change do
    create table(:assistant_messages) do
      add :thread_id, references(:assistant_threads, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :string
      add :tool_calls, {:array, :map}
      # LINE's own message id, for unsend/messageEdited correlation (Task 19).
      # Only set for messages sourced directly from an inbound LINE text event.
      add :line_message_id, :string

      timestamps(type: :utc_datetime)
    end

    create index(:assistant_messages, [:thread_id])
    create unique_index(:assistant_messages, [:line_message_id])
  end
end
