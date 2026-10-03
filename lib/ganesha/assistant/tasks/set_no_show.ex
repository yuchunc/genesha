defmodule Ganesha.Assistant.Tasks.SetNoShow do
  @moduledoc """
  `set_no_show` (spec §3.1 #17): mark an attendance as a no-show or undo it
  through `Ganesha.Roster.mark_no_show/1` and `mark_expected/1`, as the
  session screen's toggle does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Roster, Studio}
  alias GaneshaWeb.Fmt

  @apply_keys ~w(attendance_id state)

  @impl true
  def name, do: "set_no_show"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Mark a student as a no-show on one Session, or undo a no-show back to expected. \
      This only proposes a Draft; the attendance row is updated when the teacher taps \
      Confirm. Use attendance_id from session_roster or the studio snapshot.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          attendance_id: %{type: "integer"},
          state: %{
            type: "string",
            enum: ["no_show", "expected"],
            description: "no_show to mark absent; expected to undo"
          }
        },
        required: ["attendance_id", "state"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, attendance} <- fetch_attendance(input["attendance_id"]),
         :ok <- check_state(input["state"]),
         :ok <- check_transition(attendance, input["state"]),
         session <- Studio.get_session!(attendance.session_id),
         student <- People.get_student!(attendance.student_id) do
      parsed = %{
        "attendance_id" => attendance.id,
        "session_id" => session.id,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "before_state" => attendance.state,
        "state" => input["state"]
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, attendance} <- load_attendance(attrs["attendance_id"]),
         :ok <- same_state(attendance, parsed["before_state"]),
         {:ok, updated} <- apply_state(attendance, attrs["state"]) do
      {:ok, {"Ganesha.Roster.Attendance", updated.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title:
        "#{title(parsed["state"], locale)} #{parsed["student_name"]} #{short_date(date, locale)}",
      lines:
        Enum.reject(
          [
            session_line(parsed, date, locale),
            kind_line(parsed, locale)
          ],
          &is_nil/1
        ),
      changes: [
        {label(:attendance, locale), state_name(parsed["before_state"], locale),
         state_name(parsed["state"], locale)}
      ],
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp fetch_attendance(id) when is_integer(id) do
    case Roster.get_attendance(id) do
      nil -> {:error, "no attendance with id #{id}"}
      attendance -> {:ok, attendance}
    end
  end

  defp fetch_attendance(_id), do: {:error, "attendance_id must be an integer"}

  defp load_attendance(id) when is_integer(id) do
    case Roster.get_attendance(id) do
      nil -> {:error, :not_found}
      attendance -> {:ok, attendance}
    end
  end

  defp load_attendance(_id), do: {:error, :not_found}

  defp check_state(state) when state in ["no_show", "expected"], do: :ok
  defp check_state(_state), do: {:error, "state must be no_show or expected"}

  defp check_transition(%{state: current}, desired) when current == desired do
    {:error, "attendance is already #{desired}"}
  end

  defp check_transition(_attendance, _desired), do: :ok

  defp same_state(%{state: current}, before) when current == before, do: :ok
  defp same_state(_attendance, _before), do: {:error, :attendance_changed}

  defp apply_state(attendance, "no_show"), do: Roster.mark_no_show(attendance)
  defp apply_state(attendance, "expected"), do: Roster.mark_expected(attendance)

  defp parse_date(nil), do: nil

  defp parse_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp short_date(nil, _locale), do: ""
  defp short_date(date, _locale), do: Fmt.short_date(date)

  defp title("no_show", "en"), do: "No-show"
  defp title("expected", "en"), do: "Undo no-show"
  defp title("no_show", _), do: "缺席"
  defp title("expected", _), do: "取消缺席"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, _locale),
    do:
      "課堂：#{Fmt.short_date(date)} #{Fmt.weekday(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp kind_line(_parsed, _locale), do: nil

  defp label(:attendance, "en"), do: "Attendance"
  defp label(:attendance, _), do: "出席"

  defp state_name("expected", "en"), do: "Expected"
  defp state_name("no_show", "en"), do: "No-show"
  defp state_name("expected", _), do: "預期出席"
  defp state_name("no_show", _), do: "缺席"
  defp state_name(other, _), do: other
end
