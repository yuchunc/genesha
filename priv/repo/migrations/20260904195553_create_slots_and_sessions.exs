defmodule Ganesha.Repo.Migrations.CreateSlotsAndSessions do
  use Ecto.Migration

  def change do
    create table(:slots) do
      # 1 = Monday .. 7 = Sunday, matching Date.day_of_week/1.
      add :weekday, :integer, null: false
      add :start_time, :time, null: false
      add :end_time, :time, null: false
      add :default_style, :string, null: false
      add :label, :string, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create table(:sessions) do
      add :slot_id, references(:slots, on_delete: :restrict), null: false
      add :date, :date, null: false
      # Overrides the slot's default_style for this date only. This is how
      # "*基礎8/26" on a 流動 slot is represented: style belongs to the date.
      add :style, :string, null: false
      add :state, :string, null: false, default: "scheduled"
      add :cancel_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sessions, [:slot_id, :date])
    create index(:sessions, [:date])
  end
end
