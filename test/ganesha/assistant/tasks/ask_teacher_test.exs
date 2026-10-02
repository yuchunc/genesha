defmodule Ganesha.Assistant.Tasks.AskTeacherTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Tasks.AskTeacher

  test "turns the options into choices for quick-reply buttons" do
    assert {:ok, %{data: data, choices: ["週二晚班", "週四早班"]}} =
             AskTeacher.answer(
               %{"question" => "哪一位 Amy？", "options" => ["週二晚班", "週四早班"]},
               %{}
             )

    assert data =~ "週二晚班 / 週四早班"
  end

  test "accepts 13 options of 20 characters each" do
    options = for n <- 1..13, do: String.pad_leading("#{n}", 20, "選")

    assert {:ok, %{choices: ^options}} =
             AskTeacher.answer(%{"question" => "哪一堂？", "options" => options}, %{})
  end

  test "rejects fewer than 2 or more than 13 options" do
    assert {:error, message} =
             AskTeacher.answer(%{"question" => "哪一個？", "options" => ["只有一個"]}, %{})

    assert message =~ "2–13 options"

    many = for n <- 1..14, do: "選項#{n}"
    assert {:error, _} = AskTeacher.answer(%{"question" => "哪一個？", "options" => many}, %{})
  end

  test "rejects an option longer than 20 characters" do
    long = String.duplicate("長", 21)
    assert {:error, _} = AskTeacher.answer(%{"question" => "哪一個？", "options" => ["短", long]}, %{})
  end

  test "rejects a call without a question" do
    assert {:error, _} = AskTeacher.answer(%{"options" => ["A", "B"]}, %{})
  end
end
