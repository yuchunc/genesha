defmodule Ganesha.Assistant.Draft do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.{Message, Thread}
  alias Ganesha.People.Student

  @kinds ~w(payment attendance makeup_request unknown)
  @states ~w(pending applied discarded)

  schema "drafts" do
    field :kind, :string
    field :parsed, :map
    field :confidence, :float, default: 1.0
    field :state, :string, default: "pending"
    field :applied_record_type, :string
    field :applied_record_id, :integer

    belongs_to :thread, Thread
    belongs_to :origin_message, Message
    belongs_to :student, Student

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def states, do: @states

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:thread_id, :origin_message_id, :kind, :student_id, :parsed, :confidence])
    |> validate_required([:thread_id, :kind, :parsed])
    |> validate_inclusion(:kind, @kinds)
    |> put_change(:state, "pending")
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:origin_message_id)
    |> foreign_key_constraint(:student_id)
  end

  @doc "The only path to `applied`; records which ledger row it produced, if any (spec §8)."
  def apply_changeset(draft, applied_record_type, applied_record_id) do
    change(draft, %{
      state: "applied",
      applied_record_type: applied_record_type,
      applied_record_id: applied_record_id
    })
  end

  def state_changeset(draft, state) when state in @states, do: change(draft, %{state: state})
end
