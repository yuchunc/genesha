defmodule Ganesha.Repo.Migrations.CreateStudioSettings do
  use Ecto.Migration

  def change do
    # A singleton row. The announcement template lives in code; only the parts
    # she edits live here.
    create table(:studio_settings) do
      add :bank_name, :string
      add :bank_code, :string
      add :account_number, :string
      add :transfer_deadline, :string
      add :closing_note, :text

      timestamps(type: :utc_datetime)
    end
  end
end
