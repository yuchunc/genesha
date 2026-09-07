defmodule Ganesha.Repo.Migrations.CreatePurchases do
  use Ecto.Migration

  def change do
    create table(:purchases) do
      add :student_id, references(:students, on_delete: :restrict), null: false
      add :package_id, references(:packages, on_delete: :restrict), null: false
      # Set for monthly purchases only. A drop-in is not tied to a slot.
      add :slot_id, references(:slots, on_delete: :restrict)
      # Snapshot of the package price at sale time, so the price list can change
      # without rewriting history, and so an override is visible not silent.
      add :list_price, :integer, null: false
      # Freeform override. NULL means "charge list_price". Zero is meaningful:
      # 按摩器代購 is custom_amount 0 plus a note, not a null amount.
      add :custom_amount, :integer
      add :note, :string

      timestamps(type: :utc_datetime)
    end

    create index(:purchases, [:student_id])
    create index(:purchases, [:package_id])
    create index(:purchases, [:slot_id])
  end
end
