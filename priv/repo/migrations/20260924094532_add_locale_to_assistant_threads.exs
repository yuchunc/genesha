defmodule Ganesha.Repo.Migrations.AddLocaleToAssistantThreads do
  use Ecto.Migration

  def change do
    alter table(:assistant_threads) do
      add :locale, :string
    end
  end
end
