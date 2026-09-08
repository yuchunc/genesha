defmodule Ganesha.Studio.Session do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Studio.Slot

  @states ~w(scheduled cancelled)

  schema "sessions" do
    field :date, :date
    field :style, :string
    field :state, :string, default: "scheduled"
    field :cancel_reason, :string

    # Populated only when slot_id is nil — a standalone class with no
    # recurring template behind it. A recurring session derives its label
    # and time range from its slot instead.
    field :label, :string
    field :start_time, :time
    field :end_time, :time

    belongs_to :slot, Slot

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :slot_id,
      :date,
      :style,
      :state,
      :cancel_reason,
      :label,
      :start_time,
      :end_time
    ])
    |> validate_required([:date, :style, :state])
    |> validate_inclusion(:state, @states)
    |> validate_origin()
    |> unique_constraint([:slot_id, :date], name: "sessions_slot_id_date_index")
    |> foreign_key_constraint(:slot_id)
  end

  @doc "Cancellation always carries a reason; it is shown to students in the roster."
  def cancellation_changeset(session, reason) do
    session
    |> cast(%{cancel_reason: reason}, [:cancel_reason])
    |> put_change(:state, "cancelled")
    |> validate_required([:cancel_reason])
  end

  # A session is either a dated occurrence of a recurring slot, or a
  # standalone class carrying its own label and time range — never both,
  # never neither.
  defp validate_origin(changeset) do
    slot_id = get_field(changeset, :slot_id)

    standalone_fields = [
      get_field(changeset, :label),
      get_field(changeset, :start_time),
      get_field(changeset, :end_time)
    ]

    cond do
      is_nil(slot_id) and Enum.all?(standalone_fields, &(!is_nil(&1))) ->
        changeset

      !is_nil(slot_id) and Enum.all?(standalone_fields, &is_nil/1) ->
        changeset

      is_nil(slot_id) ->
        add_error(changeset, :label, "單次的課需要日期、時間與名稱")

      true ->
        add_error(changeset, :slot_id, "固定班次的課不需要另外填寫名稱與時間")
    end
  end
end
