defmodule Ganesha.Repo.Migrations.CreateBlockedAccounts do
  use Ecto.Migration

  def change do
    create table(:blocked_accounts) do
      add :kind, :string, null: false
      add :line_id, :string, null: false
      add :label, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:blocked_accounts, [:kind, :line_id])
  end
end
