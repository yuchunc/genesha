defmodule Ganesha.Repo.Migrations.CreateMonthlyCloses do
  use Ecto.Migration

  def change do
    create table(:monthly_closes) do
      # Always the 1st of the month. Frozen once written; a later
      # confirmation into this month overwrites the row rather than
      # creating a new one.
      add :month, :date, null: false
      add :revenue, :integer, null: false
      add :revenue_by_method, :map, null: false
      # Snapshot of the tax threshold at close time, recorded for
      # potential future use. Nothing in the codebase reads it back today.
      add :tax_threshold, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:monthly_closes, [:month])
  end
end
