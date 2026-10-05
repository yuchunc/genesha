defmodule Ganesha.Repo.Migrations.AddSenderToAssistantMessages do
  use Ecto.Migration

  def change do
    alter table(:assistant_messages) do
      add :sender_id, :string
      add :sender_name, :string
    end
  end
end
