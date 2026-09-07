defmodule Ganesha.Repo.Migrations.CreatePackages do
  use Ecto.Migration

  def change do
    create table(:packages) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :price_per_class, :integer, null: false
      # How many makeup credits a purchase of this package grants. 1 for the
      # monthly package, 0 for drop-in and trial. Policy lives in data.
      add :included_makeups, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:packages, [:name])
  end
end
