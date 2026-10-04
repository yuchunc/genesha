defmodule Ganesha.Assistant.Tasks.Lookup do
  @moduledoc false

  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  def session_payload(session, roster, locale) do
    %{
      "title" => session_title(session, locale),
      "style" => session.style,
      "count" => length(roster),
      "cancelled" => session.state == "cancelled",
      "attendees" => Enum.map(roster, &attendee_payload/1)
    }
  end

  def session_data(session, roster, ctx) do
    title = session_title(session, ctx.locale)
    # Each attendee with the attendance id `set_no_show` needs.
    names =
      Enum.map_join(roster, ", ", fn a ->
        "#{a.student.display_name} (attendance #{a.id}, #{a.state})"
      end)

    base =
      "Session #{session.id}: #{title}, #{length(roster)} booked" <>
        if(session.state == "cancelled", do: " (cancelled)", else: "")

    if names == "", do: base, else: base <> ". #{names}"
  end

  def session_title(session, locale) do
    day = Format.session_day(session.date, locale)
    label = Fmt.session_label(session)
    time = Fmt.session_time_range(session)
    Enum.join([day, label, time], " ")
  end

  def attendee_payload(attendance) do
    %{
      "name" => attendance.student.display_name,
      "kind" => attendance.kind,
      "no_show" => attendance.state == "no_show"
    }
  end

  def parse_month(nil, today), do: Date.beginning_of_month(today)

  def parse_month(text, _today) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> Date.beginning_of_month(date)
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  def parse_month(_other, _today), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  def fetch_student(id) when is_integer(id) do
    case Ganesha.People.get_student(id) do
      nil -> {:error, "no student with id #{id}; use a student id from the snapshot"}
      student -> {:ok, student}
    end
  end

  def fetch_student(_id), do: {:error, "student_id must be a student id from the snapshot"}

  def fetch_session(id) when is_integer(id) do
    case Ganesha.Studio.get_session(id) do
      nil -> {:error, "no session with id #{id}; use a session id from the snapshot"}
      session -> {:ok, session}
    end
  end

  def fetch_session(_id), do: {:error, "session_id must be a session id from the snapshot"}

  @doc "Confirm-time Session load: `{:error, :not_found}` instead of a message for the model."
  @spec load_session(term()) :: {:ok, %Ganesha.Studio.Session{}} | {:error, :not_found}
  def load_session(id) when is_integer(id) do
    case Ganesha.Studio.get_session(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  def load_session(_id), do: {:error, :not_found}
end
