defmodule Ganesha.Assistant.Tasks do
  @moduledoc """
  Which chat gets which tasks (spec §2 rule 7), lookup by name, and the tool
  schemas the model sees (spec §4.2). Schemas use the atom-keyed shape
  `Ganesha.Assistant.Provider.Anthropic` sends: `name`, `description`,
  `input_schema`.
  """

  alias Ganesha.Assistant.Tasks.{
    AskTeacher,
    BookOneOff,
    MakeupRequest,
    MonthMoney,
    MonthSchedule,
    NextSession,
    OpenCredits,
    RecordPayment,
    SessionRoster,
    SetLanguage,
    StudentSummary
  }

  @questions [
    NextSession,
    MonthSchedule,
    SessionRoster,
    StudentSummary,
    MonthMoney,
    OpenCredits
  ]

  @teacher @questions ++ [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage]
  @group [RecordPayment, BookOneOff, MakeupRequest]
  @student [SetLanguage]

  @spec for_chat(:teacher | :group | :student) :: [module()]
  def for_chat(:teacher), do: @teacher
  def for_chat(:group), do: @group
  def for_chat(:student), do: @student

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) when is_binary(name) do
    case Enum.find(all(), &(&1.name() == name)) do
      nil -> :error
      task -> {:ok, task}
    end
  end

  def fetch(_name), do: :error

  @spec tool_schemas([module()]) :: [map()]
  def tool_schemas(tasks) do
    Enum.map(tasks, fn task ->
      %{description: description, input_schema: input_schema} = task.tool()

      %{
        name: task.name(),
        description: description,
        input_schema: add_shared_fields(input_schema, task.kind())
      }
    end)
  end

  defp all, do: Enum.uniq(@teacher ++ @group ++ @student)

  defp add_shared_fields(schema, :change) do
    put_property(schema, :replaces_draft_id, %{
      type: "integer",
      description: "When correcting a pending Draft, that Draft's id; the old Draft is replaced."
    })
  end

  defp add_shared_fields(schema, :lookup) do
    put_property(schema, :show_card, %{
      type: "boolean",
      description: "true to also show the teacher this answer as a card."
    })
  end

  defp add_shared_fields(schema, :control), do: schema

  defp put_property(schema, key, property) do
    Map.update(schema, :properties, %{key => property}, &Map.put(&1, key, property))
  end
end
