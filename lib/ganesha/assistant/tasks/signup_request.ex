defmodule Ganesha.Assistant.Tasks.SignupRequest do
  @moduledoc """
  `signup_request` (spec 2026-10-06 §1): someone in a Student chat asked to
  sign up for a class. The Draft is acknowledged only; confirming books
  nothing. The teacher enrolls them herself, or through 「幫他報名」.

  Who asked comes from the Student chat, never from the model: the student
  linked to the chat's LINE user id, or else a newcomer named by their LINE
  profile.
  """
  @behaviour Ganesha.Assistant.Task

  require Logger

  alias Ganesha.People

  @impl true
  def name, do: "signup_request"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      The person wants to sign up for a class. Pass on what they asked for in their own \
      words so the teacher can follow up. You cannot see the timetable or prices; never \
      add a time, date or price they did not say.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          note: %{
            type: "string",
            description: "What they asked for, e.g. 想報名週一晚上的課，11月開始"
          }
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def propose(input, %{thread: %{source_id: line_user_id}}) do
    with {:ok, note} <- fetch_note(input["note"]) do
      {:ok, asker(line_user_id, note)}
    end
  end

  @impl true
  def apply(_parsed, _confirmed_by), do: {:ok, {nil, nil}}

  @impl true
  def summary(%{"new" => false} = parsed, "en"),
    do: "#{parsed["student_name"]} wants to sign up: #{parsed["note"]}"

  def summary(%{"new" => false} = parsed, _locale),
    do: "#{parsed["student_name"]} 想報名：#{parsed["note"]}"

  def summary(%{"line_name" => name} = parsed, "en") when is_binary(name),
    do: "Unlinked LINE user (LINE: #{name}) wants to sign up: #{parsed["note"]}"

  def summary(parsed, "en"), do: "An unlinked LINE user wants to sign up: #{parsed["note"]}"

  def summary(%{"line_name" => name} = parsed, _locale) when is_binary(name),
    do: "未連結的 LINE 用戶（LINE：#{name}）想報名：#{parsed["note"]}"

  def summary(parsed, _locale), do: "未連結的 LINE 用戶想報名：#{parsed["note"]}"

  @doc """
  What 「幫他報名」 adds to the Teacher chat as her message (spec 2026-10-06
  §5), so the model proposes enroll, or add_student first for a newcomer.
  """
  @spec teacher_message(pos_integer(), map(), String.t()) :: String.t()
  def teacher_message(id, %{"new" => false} = parsed, "en") do
    note = parsed["note"]

    "[Sign-up request ##{id}] Sign up #{parsed["student_name"]} " <>
      "(student ##{parsed["student_id"]}). #{quoted_words(note, "en")}"
  end

  def teacher_message(id, %{"new" => false} = parsed, locale) do
    note = parsed["note"]

    "[報名申請 ##{id}] 幫 #{parsed["student_name"]}（學生 ##{parsed["student_id"]}）" <>
      "報名。#{quoted_words(note, locale)}"
  end

  def teacher_message(id, parsed, "en") do
    line = line_label(parsed, "en")
    note = parsed["note"]

    "[Sign-up request ##{id}] #{line}This LINE ID isn't linked to a student. " <>
      "#{quoted_words(note, "en")} Check the snapshot for a student " <>
      "matching the LINE display name or their words; if none, add a student with " <>
      "this LINE user id, then ask her to say 「繼續」 after confirming."
  end

  def teacher_message(id, parsed, locale) do
    line = line_label(parsed, locale)
    note = parsed["note"]

    "[報名申請 ##{id}] #{line}這個 LINE ID 還沒連結任何學生。" <>
      "#{quoted_words(note, locale)}" <>
      "請先在名冊中查看 LINE 顯示名稱或報名內容是否有相符的學生；" <>
      "若沒有，再新增學生並連結此 LINE ID，確認後跟我說「繼續」。"
  end

  defp quoted_words(note, "en"), do: ~s|Their words: "#{note}". |
  defp quoted_words(note, _locale), do: "學生原話：「#{note}」。"

  defp line_label(%{"line_name" => name} = parsed, _locale) when is_binary(name),
    do: "LINE display name #{name}; LINE ID #{line_id(parsed)}. "

  defp line_label(parsed, "en"), do: "LINE ID #{line_id(parsed)}. "
  defp line_label(parsed, _locale), do: "LINE ID #{line_id(parsed)}，"

  defp line_id(%{"line_user_id" => id}), do: id

  defp asker(line_user_id, note) do
    case People.find_by_line_user_id(line_user_id) do
      %People.Student{} = student ->
        %{
          student_id: student.id,
          parsed: %{
            "note" => note,
            "student_id" => student.id,
            "student_name" => student.display_name,
            "line_user_id" => line_user_id,
            "line_name" => nil,
            "new" => false
          }
        }

      nil ->
        %{
          student_id: nil,
          parsed: %{
            "note" => note,
            "student_id" => nil,
            "student_name" => nil,
            "line_user_id" => line_user_id,
            "line_name" => line_name(line_user_id),
            "new" => true
          }
        }
    end
  end

  defp line_name(line_user_id) do
    case line_client().get_profile(line_user_id) do
      {:ok, %{"displayName" => name}} when is_binary(name) and name != "" ->
        name

      other ->
        Logger.warning("LINE profile lookup failed for #{line_user_id}: #{inspect(other)}")
        nil
    end
  end

  @max_note_length 300

  defp fetch_note(note) when is_binary(note) do
    trimmed = String.trim(note)

    cond do
      trimmed == "" -> {:error, missing_note()}
      String.length(trimmed) > @max_note_length -> {:error, note_too_long()}
      true -> {:ok, trimmed}
    end
  end

  defp fetch_note(_note), do: {:error, missing_note()}

  defp missing_note, do: "signup_request needs a note saying what the person asked for"

  defp note_too_long,
    do: "signup_request note is too long (#{@max_note_length} characters max); shorten it"

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
