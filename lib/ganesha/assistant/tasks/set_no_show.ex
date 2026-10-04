defmodule Ganesha.Assistant.Tasks.SetNoShow do
  @moduledoc """
  `set_no_show` (spec §3.1 #17): mark an attendance as a no-show or undo it
  through `Ganesha.Roster.mark_no_show/1` and `mark_expected/1`, as the
  session screen's toggle does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Roster, Studio}
  alias Ganesha.Assistant.Summary
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
      Confirm. Get attendance_id by calling session_roster for the Session first.\
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
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"

    session =
      Summary.words([Summary.day(parsed["session_date"], locale), parsed["session_label"]])

    case {parsed["state"], locale} do
      {"no_show", "en"} -> "Mark #{name} absent from #{session}"
      {"no_show", _} -> "把 #{name} #{session} 記為缺席"
      {_, "en"} -> "Mark #{name} as coming to #{session} again"
      {_, _} -> "#{name} #{session} 改回會來"
    end
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
end
