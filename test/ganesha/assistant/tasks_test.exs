defmodule Ganesha.Assistant.TasksTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Tasks

  alias Ganesha.Assistant.Tasks.{
    AddSession,
    AddSlot,
    AskTeacher,
    BookOneOff,
    CancelSession,
    CopyMonth,
    MakeupRequest,
    MonthMoney,
    MonthSchedule,
    NextSession,
    OpenCredits,
    RecordPayment,
    SessionRoster,
    SetLanguage,
    SetSessionStyle,
    StudentSummary
  }

  defmodule Lookup do
    @behaviour Ganesha.Assistant.Task
    def name, do: "lookup_thing"
    def kind, do: :lookup

    def tool,
      do: %{
        description: "looks up",
        input_schema: %{type: "object", properties: %{q: %{type: "string"}}}
      }

    def answer(_input, _ctx), do: {:ok, %{data: "x"}}
  end

  test "each chat gets its own tasks (spec §2 rule 7)" do
    assert Tasks.for_chat(:group) == [RecordPayment, BookOneOff, MakeupRequest]
    assert Tasks.for_chat(:student) == [SetLanguage]

    teacher = Tasks.for_chat(:teacher)

    for task <- [RecordPayment, BookOneOff, MakeupRequest, AskTeacher, SetLanguage] do
      assert task in teacher
    end
  end

  test "the six questions are Teacher chat lookups only" do
    teacher = Tasks.for_chat(:teacher)
    group = Tasks.for_chat(:group)
    student = Tasks.for_chat(:student)

    for task <- [
          NextSession,
          MonthSchedule,
          SessionRoster,
          StudentSummary,
          MonthMoney,
          OpenCredits
        ] do
      assert task in teacher
      refute task in group
      refute task in student
      assert task.kind() == :lookup
      assert {:ok, ^task} = Tasks.fetch(task.name())
    end
  end

  test "the five schedule change tasks are Teacher chat only" do
    teacher = Tasks.for_chat(:teacher)
    group = Tasks.for_chat(:group)
    student = Tasks.for_chat(:student)

    for task <- [CancelSession, SetSessionStyle, AddSession, AddSlot, CopyMonth] do
      assert task in teacher
      refute task in group
      refute task in student
      assert task.kind() == :change
      assert {:ok, ^task} = Tasks.fetch(task.name())
    end
  end

  test "fetch/1 finds a task by name" do
    assert {:ok, RecordPayment} = Tasks.fetch("record_payment")
    assert {:ok, AskTeacher} = Tasks.fetch("ask_teacher")
    assert :error = Tasks.fetch("payment")
    assert :error = Tasks.fetch(nil)
  end

  test "tool_schemas/1 names each tool and adds the shared fields by kind" do
    [payment, ask, lookup] = Tasks.tool_schemas([RecordPayment, AskTeacher, Lookup])

    assert payment.name == "record_payment"
    assert payment.input_schema.properties.replaces_draft_id.type == "integer"
    assert payment.input_schema.required == ["student_id", "amount", "method"]
    refute Map.has_key?(payment.input_schema.properties, :show_card)

    assert ask.name == "ask_teacher"
    assert ask.input_schema == AskTeacher.tool().input_schema

    assert lookup.name == "lookup_thing"
    assert lookup.description == "looks up"
    assert lookup.input_schema.properties.show_card.type == "boolean"
    refute Map.has_key?(lookup.input_schema.properties, :replaces_draft_id)
  end
end
