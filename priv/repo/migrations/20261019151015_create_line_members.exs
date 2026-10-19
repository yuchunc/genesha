defmodule Ganesha.Repo.Migrations.CreateLineMembers do
  use Ecto.Migration

  def change do
    create table(:line_members) do
      add :line_user_id, :string, null: false
      add :display_name, :string, null: false
      add :state, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:line_members, [:line_user_id])
  end
end
