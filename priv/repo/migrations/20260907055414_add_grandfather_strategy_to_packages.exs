defmodule Ganesha.Repo.Migrations.AddGrandfatherStrategyToPackages do
  use Ecto.Migration

  def change do
    alter table(:packages) do
      # Governs who may still buy an inactive package. "none" (the default,
      # and today's only behaviour) closes it to everyone once inactive.
      # "past_purchasers" keeps it open to students who have already bought
      # it, closed to anyone new. Only consulted while active is false.
      add :grandfather_strategy, :string, null: false, default: "none"
    end
  end
end
