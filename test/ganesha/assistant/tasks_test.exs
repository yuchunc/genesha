defmodule Ganesha.Assistant.TasksTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Tasks

  alias Ganesha.Assistant.Tasks.{
    AddSession,
    AddSlot,
    AddStudent,
    AskTeacher,
    BlockAccount,
    BookMakeup,
    BookOneOff,
    CancelSession,
    ConfirmPayment,
    CopyMonth,
    Enroll,
    Listening,
    MakeupRequest,
    OverridePrice,
    MonthMoney,
    MonthSchedule,
    NextSession,
    OpenCredits,
    PendingDrafts,
    RecordPayment,
    SavePackage,
    SessionRoster,
    SetLanguage,
    SetNoShow,
    SetSessionStyle,
    SignupRequest,
    StudentSummary,
    UnblockAccount
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
    assert Tasks.for_chat(:student) == [SetLanguage, SignupRequest]

    teacher = Tasks.for_chat(:teacher)

    for task <- [
          RecordPayment,
          BookOneOff,
          MakeupRequest,
          AskTeacher,
          SetLanguage,
          Enroll,
          ConfirmPayment,
          OverridePrice,
          SetNoShow,
          BookMakeup,
          AddStudent,
          SavePackage
        ] do
      assert task in teacher
    end
  end

  test "the seven student and money change tasks are Teacher chat only" do
    teacher = Tasks.for_chat(:teacher)
    group = Tasks.for_chat(:group)
    student = Tasks.for_chat(:student)

    for task <- [
          Enroll,
          ConfirmPayment,
          OverridePrice,
          SetNoShow,
          BookMakeup,
          AddStudent,
          SavePackage
        ] do
      assert task in teacher
      refute task in group
      refute task in student
      assert task.kind() == :change
      assert {:ok, ^task} = Tasks.fetch(task.name())
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

  test "pending_drafts is Teacher chat only" do
    teacher = Tasks.for_chat(:teacher)
    group = Tasks.for_chat(:group)
    student = Tasks.for_chat(:student)

    assert PendingDrafts in teacher
    refute PendingDrafts in group
    refute PendingDrafts in student
    assert PendingDrafts.kind() == :lookup
    assert {:ok, PendingDrafts} = Tasks.fetch("pending_drafts")
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
    assert lookup.input_schema == Lookup.tool().input_schema
    refute Map.has_key?(lookup.input_schema.properties, :show_card)
  end

  test "no lookup offers show_card" do
    for task <- Tasks.for_chat(:teacher), task.kind() == :lookup do
      [schema] = Tasks.tool_schemas([task])
      refute Map.has_key?(schema.input_schema.properties, :show_card)
    end
  end

  test "listening, block_account and unblock_account are Teacher chat only" do
    for task <- [Listening, BlockAccount, UnblockAccount] do
      assert task in Tasks.for_chat(:teacher)
      refute task in Tasks.for_chat(:group)
      refute task in Tasks.for_chat(:student)
    end
  end

  test "signup_request is Student chat only" do
    assert SignupRequest in Tasks.for_chat(:student)
    refute SignupRequest in Tasks.for_chat(:teacher)
    refute SignupRequest in Tasks.for_chat(:group)
  end
end
