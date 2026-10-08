defmodule Ganesha.Assistant.Tasks.SignupRequest do
  @moduledoc """
  `signup_request` (spec 2026-10-06 §1): someone asked to sign up for a class,
  in a Student chat or the Group chat. Confirming (「已處理」) only
  acknowledges it, for a request settled outside LINE. 「幫他報名」 asks the
  model for an `enroll` Draft carrying this request's id, whose confirm
  books the class and settles the request (spec 2026-10-07 §2, §4).

  Who asked never comes from the model. In a Student chat it is the chat's
  LINE user, named by their LINE profile when unlinked. In the Group chat it
  is the sender of the message being handled, named by the group display
  name `ProcessEventWorker` stored with it (spec 2026-10-06 §8).
  Either way the student linked to that LINE user id wins when there is one.
  """
  @behaviour Ganesha.Assistant.Task

  require Logger

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.Thread

  @impl true
  def name, do: "signup_request"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      The person wants to sign up for a class. Pass on what they asked for in their own \
      words so the teacher can follow up. Never add a time, date or price they did not say.\
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
  def propose(input, %{thread: thread}) do
    with {:ok, note} <- fetch_note(input["note"]),
         {:ok, line_user_id, line_name} <- who_asked(thread) do
      {:ok, asker(line_user_id, line_name, note)}
    end
  end

  # Each returns the LINE user id and a function naming them if unlinked, so
  # LINE is only asked for a profile when the name is actually needed.
  defp who_asked(%Thread{source_type: "user", source_id: line_user_id}),
    do: {:ok, line_user_id, fn -> profile_name(line_user_id) end}

  defp who_asked(%Thread{source_type: "group"} = thread) do
    case Assistant.latest_user_message(thread) do
      %{sender_id: sender_id, sender_name: sender_name} when is_binary(sender_id) ->
        {:ok, sender_id, fn -> sender_name end}

      _ ->
        {:error, "cannot tell who sent this group message; propose nothing"}
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
  What 「幫他報名」 adds to the Teacher chat as her message (spec 2026-10-07
  §4), so the model proposes one `enroll` with this request's id: for the
  linked student, or for a snapshot match or a new student when unlinked.
  """
  @spec teacher_message(pos_integer(), map(), String.t()) :: String.t()
  def teacher_message(id, %{"new" => false} = parsed, "en") do
    "[Sign-up request ##{id}] Sign up #{parsed["student_name"]} " <>
      "(student ##{parsed["student_id"]}). #{quoted_words(parsed["note"], "en")}" <>
      "Propose enroll with signup_request_id #{id} and student_id #{parsed["student_id"]}."
  end

  def teacher_message(id, %{"new" => false} = parsed, locale) do
    "[報名申請 ##{id}] 幫 #{parsed["student_name"]}（學生 ##{parsed["student_id"]}）" <>
      "報名。#{quoted_words(parsed["note"], locale)}" <>
      "請提出 enroll，帶 signup_request_id #{id} 和 student_id #{parsed["student_id"]}。"
  end

  def teacher_message(id, parsed, "en") do
    "[Sign-up request ##{id}] #{line_label(parsed, "en")}This LINE ID isn't linked to a " <>
      "student. #{quoted_words(parsed["note"], "en")}Propose enroll with " <>
      "signup_request_id #{id}. Check the snapshot for a student matching the LINE display " <>
      "name or their words: if one fits, pass that student_id; if none does, pass " <>
      "new_student_name (#{name_hint(parsed, "en")}). Call ask_teacher only when the match " <>
      "is unclear."
  end

  def teacher_message(id, parsed, locale) do
    "[報名申請 ##{id}] #{line_label(parsed, locale)}這個 LINE ID 還沒連結任何學生。" <>
      "#{quoted_words(parsed["note"], locale)}" <>
      "請提出 enroll，帶 signup_request_id #{id}。先在名冊中查看 LINE 顯示名稱或報名內容" <>
      "是否有相符的學生：有就帶那位的 student_id；沒有就帶 new_student_name" <>
      "（#{name_hint(parsed, locale)}）。只有分不清是哪位時才用 ask_teacher。"
  end

  defp quoted_words(note, "en"), do: ~s|Their words: "#{note}". |
  defp quoted_words(note, _locale), do: "學生原話：「#{note}」。"

  defp line_label(%{"line_name" => name} = parsed, "en") when is_binary(name),
    do: "LINE display name #{name}; LINE ID #{line_id(parsed)}. "

  defp line_label(%{"line_name" => name} = parsed, _locale) when is_binary(name),
    do: "LINE 顯示名稱 #{name}，LINE ID #{line_id(parsed)}，"

  defp line_label(parsed, "en"), do: "LINE ID #{line_id(parsed)}. "
  defp line_label(parsed, _locale), do: "LINE ID #{line_id(parsed)}，"

  defp name_hint(%{"line_name" => name}, "en") when is_binary(name),
    do: "#{name}, their LINE display name, unless the teacher says otherwise"

  defp name_hint(%{"line_name" => name}, _locale) when is_binary(name),
    do: "用 LINE 顯示名稱 #{name}，除非老師另外指定"

  defp name_hint(_parsed, "en"), do: "the name the teacher gives; ask her if she gave none"
  defp name_hint(_parsed, _locale), do: "用老師給的名字；她沒說就問她"

  defp line_id(%{"line_user_id" => id}), do: id

  defp asker(line_user_id, line_name, note) do
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
            "line_name" => line_name.(),
            "new" => true
          }
        }
    end
  end

  defp profile_name(line_user_id) do
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
