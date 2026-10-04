defmodule Ganesha.Assistant.Tasks.MakeupRequestTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.Tasks.MakeupRequest

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "records what the student asked for and who asked", %{ctx: ctx} do
    {:ok, student} = People.create_student(%{display_name: "蘭子"})

    assert {:ok, %{student_id: student_id, parsed: parsed}} =
             MakeupRequest.propose(
               %{"student_id" => student.id, "note" => " 想補 8/17 或 8/31 "},
               ctx
             )

    assert student_id == student.id

    assert parsed == %{
             "note" => "想補 8/17 或 8/31",
             "student_id" => student.id,
             "student_name" => "蘭子"
           }
  end

  test "can be made without knowing the student", %{ctx: ctx} do
    assert {:ok, %{student_id: nil, parsed: %{"student_id" => nil}}} =
             MakeupRequest.propose(%{"note" => "有人想補課"}, ctx)
  end

  test "rejects an unknown student and a blank note", %{ctx: ctx} do
    assert {:error, message} = MakeupRequest.propose(%{"student_id" => -1, "note" => "x"}, ctx)
    assert message =~ "no student with id -1"

    assert {:error, message} = MakeupRequest.propose(%{"note" => "  "}, ctx)
    assert message =~ "needs a note"
  end

  test "confirming only acknowledges it" do
    assert {:ok, {nil, nil}} = MakeupRequest.apply(%{"note" => "8/17"}, "line:teacher")
  end

  test "summary says who asked and what they asked for" do
    zh = MakeupRequest.summary(%{"student_name" => "蘭子", "note" => "想補 8/17"}, "zh-TW")

    assert zh =~ "蘭子"
    assert zh =~ "想補 8/17"
    assert MakeupRequest.summary(%{"note" => "8/17"}, "en") =~ "8/17"
  end
end
