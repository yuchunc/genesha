defmodule Ganesha.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments) do
      add :purchase_id, references(:purchases, on_delete: :restrict), null: false
      # The amount applied to THIS purchase, not the bank transaction total.
      # One transfer split across two slots is recorded as two rows.
      add :amount, :integer, null: false
      add :method, :string, null: false
      add :state, :string, null: false, default: "claimed"
      add :paid_on, :date, null: false
      # 帳後五碼. Deliberately NOT unique: split rows share it legitimately.
      add :reported_last5, :string
      add :source, :string, null: false, default: "manual"
      add :note, :string
      add :confirmed_at, :utc_datetime
      add :confirmed_by, :string

      timestamps(type: :utc_datetime)
    end

    create index(:payments, [:purchase_id])
    create index(:payments, [:state])
    create index(:payments, [:reported_last5])
  end
end
