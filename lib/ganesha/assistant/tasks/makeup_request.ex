defmodule Ganesha.Assistant.Tasks.MakeupRequest do
  @moduledoc """
  `makeup_request` (spec §3.1 #21): a student asked for a makeup. Confirming
  (「已處理」) only acknowledges it, for a makeup arranged outside LINE.
  「幫他補課」 asks the model for a `book_makeup` Draft carrying this
  request's id, whose confirm books the makeup and settles the request
  (spec 2026-10-07 §3, §4).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.People

  @impl true
  def name, do: "makeup_request"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Note that a student asked for a makeup class so the teacher can arrange it. \
      Confirming only acknowledges it; nothing is booked. Leave student_id out if you \
      cannot tell who it is.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          note: %{type: "string", description: "What the student asked for, e.g. 想補 8/17 或 8/31"}
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, note} <- fetch_note(input["note"]),
         {:ok, student} <- fetch_student(input["student_id"]) do
      student_id = student && student.id

      {:ok,
       %{
         student_id: student_id,
         parsed: %{
           "note" => note,
           "student_id" => student_id,
           "student_name" => student && student.display_name
         }
       }}
    end
  end

  @impl true
  def apply(_parsed, _confirmed_by), do: {:ok, {nil, nil}}

  @impl true
  def summary(parsed, "en"),
    do: "#{parsed["student_name"] || "Someone"} asked for a makeup: #{parsed["note"]}"

  def summary(parsed, _locale),
    do: "#{parsed["student_name"] || "有人"}想補課：#{parsed["note"]}"

  @doc """
  What 「幫他補課」 adds to the Teacher chat as her message (spec 2026-10-07
  §4), so the model proposes one `book_makeup` with this request's id.
  """
  @spec teacher_message(pos_integer(), map(), String.t()) :: String.t()
  def teacher_message(id, parsed, "en") do
    "[Makeup request ##{id}] #{who(parsed, "en")} asked for a makeup. " <>
      ~s|Their words: "#{parsed["note"]}". | <>
      "Propose book_makeup with makeup_request_id #{id}, choosing the session from the " <>
      "snapshot and the credit from open_credits. Call ask_teacher only when the student, " <>
      "session or credit is unclear."
  end

  def teacher_message(id, parsed, _locale) do
    "[補課申請 ##{id}] #{who(parsed, "zh-TW")}想補課。學生原話：「#{parsed["note"]}」。" <>
      "請提出 book_makeup，帶 makeup_request_id #{id}，從名冊選課堂、從 open_credits 選補課券。" <>
      "只有分不清學生、課堂或補課券時才用 ask_teacher。"
  end

  defp who(%{"student_id" => id, "student_name" => name}, "en") when is_integer(id),
    do: "#{name} (student ##{id})"

  defp who(%{"student_id" => id, "student_name" => name}, _locale) when is_integer(id),
    do: "#{name}（學生 ##{id}）"

  defp who(_parsed, "en"), do: "A student not yet identified"
  defp who(_parsed, _locale), do: "一位還沒認出是誰的學生"

  defp fetch_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> {:error, missing_note()}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_note(_note), do: {:error, missing_note()}

  defp missing_note, do: "makeup_request needs a note saying what the student asked for"

  defp fetch_student(nil), do: {:ok, nil}

  defp fetch_student(id) when is_integer(id) do
    case People.get_student(id) do
      nil ->
        {:error, "no student with id #{id}; use a student id from the snapshot, or leave it out"}

      student ->
        {:ok, student}
    end
  end

  defp fetch_student(_id), do: {:error, "student_id must be an integer id from the snapshot"}
end
