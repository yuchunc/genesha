defmodule Ganesha.Repo.Migrations.AddUniqueIndexToSlotsWeekdayStartTime do
  use Ecto.Migration

  def change do
    create unique_index(:slots, [:weekday, :start_time])
  end
end
