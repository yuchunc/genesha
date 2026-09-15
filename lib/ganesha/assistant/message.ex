defmodule Ganesha.Assistant.Message do
  use Ecto.Schema
  import Ecto.Changeset

  alias Ganesha.Assistant.Thread

  @roles ~w(user assistant tool)

  schema "assistant_messages" do
    field :role, :string
    field :content, :string
    field :tool_calls, {:array, :map}
    field :line_message_id, :string

    belongs_to :thread, Thread

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:thread_id, :role, :content, :tool_calls, :line_message_id])
    |> validate_required([:thread_id, :role])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:thread_id)
    |> unique_constraint(:line_message_id)
  end
end
