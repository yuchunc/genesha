defmodule Ganesha.Publishing.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "studio_settings" do
    field :bank_name, :string
    field :bank_code, :string
    field :account_number, :string
    field :transfer_deadline, :string
    field :closing_note, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    cast(settings, attrs, [
      :bank_name,
      :bank_code,
      :account_number,
      :transfer_deadline,
      :closing_note
    ])
  end
end
