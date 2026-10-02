defmodule Ganesha.Assistant.Draft do
  @moduledoc """
  A ledger change the assistant proposed and the teacher has not confirmed
  (GLOSSARY: Draft). `kind` is the name of the task that proposed it; `parsed`
  holds that task's details, including "before" values (spec §5.1).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.{Message, Tasks, Thread}
  alias Ganesha.People.Student

  @states ~w(pending applied discarded replaced failed)

  schema "drafts" do
    field :kind, :string
    field :parsed, :map
    field :confidence, :float, default: 1.0
    field :state, :string, default: "pending"
    field :applied_record_type, :string
    field :applied_record_id, :integer
    field :failure_reason, :string
    field :notified_at, :utc_datetime

    belongs_to :thread, Thread
    belongs_to :origin_message, Message
    belongs_to :student, Student
    belongs_to :replaced_by, __MODULE__

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  def states, do: @states

  def changeset(draft, attrs) do
    draft
    |> cast(attrs, [:thread_id, :origin_message_id, :kind, :student_id, :parsed, :confidence])
    |> validate_required([:thread_id, :kind, :parsed])
    |> validate_kind()
    |> put_change(:state, "pending")
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:origin_message_id)
    |> foreign_key_constraint(:student_id)
  end

  @doc "The only path to `applied`; records which ledger row it produced, if any."
  def apply_changeset(draft, applied_record_type, applied_record_id) do
    change(draft, %{
      state: "applied",
      applied_record_type: applied_record_type,
      applied_record_id: applied_record_id
    })
  end

  # Only on insert: applied and discarded rows keep retired kinds
  # (`payment` before its rename, `attendance`, `unknown`) as history.
  defp validate_kind(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset) do
    validate_change(changeset, :kind, fn :kind, kind ->
      case Tasks.fetch(kind) do
        {:ok, task} -> if task.kind() == :change, do: [], else: [kind: "is invalid"]
        :error -> [kind: "is invalid"]
      end
    end)
  end

  defp validate_kind(changeset), do: changeset
end
