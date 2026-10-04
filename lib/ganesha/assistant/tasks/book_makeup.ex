defmodule Ganesha.Assistant.Tasks.BookMakeup do
  @moduledoc """
  `book_makeup` (spec §3.1 #18): spend a Credit on a Session through
  `Ganesha.Roster.book_makeup/3`, as the session screen does with the first
  available credit for that date.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Roster, Studio}
  alias GaneshaWeb.Fmt

  @apply_keys ~w(session_id student_id credit_id)

  @impl true
  def name, do: "book_makeup"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Book a makeup class for a student into one Session using one of their open \
      Credits. This only proposes a Draft; the makeup attendance and the spent credit \
      are created when the teacher taps Confirm. Use session_id, student_id and \
      credit_id from the studio snapshot or open_credits / student_summary. The \
      credit must still be unspent and valid on the session date.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          session_id: %{type: "integer"},
          credit_id: %{type: "integer"}
        },
        required: ["student_id", "session_id", "credit_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, student} <- fetch(:student, input["student_id"]),
         {:ok, session} <- fetch(:session, input["session_id"]),
         :ok <- check_scheduled(session),
         {:ok, credit} <- fetch_credit(input["credit_id"], student, session),
         roster = Roster.list_for_session(session),
         :ok <- check_not_booked(roster, student) do
      parsed = %{
        "student_id" => student.id,
        "session_id" => session.id,
        "credit_id" => credit.id,
        "student_name" => student.display_name,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "credit_source" => credit.source,
        "credit_expires_on" =>
          if(credit.expires_on, do: Date.to_iso8601(credit.expires_on), else: nil),
        "before_count" => length(roster)
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <- load(:student, attrs["student_id"]),
         {:ok, session} <- load(:session, attrs["session_id"]),
         :ok <- still_scheduled(session),
         {:ok, credit} <- load_credit(attrs["credit_id"], student, session),
         :ok <- credit_still_available(credit),
         {:ok, attendance} <- Roster.book_makeup(session, student, credit) do
      {:ok, {"Ganesha.Roster.Attendance", attendance.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title: "#{title(locale)} #{parsed["student_name"]} #{short_date(date)}",
      lines:
        Enum.reject(
          [
            session_line(parsed, date, locale),
            credit_line(parsed, locale)
          ],
          &is_nil/1
        ),
      changes: roster_change(parsed["before_count"], locale),
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp fetch(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, "no #{what} with id #{id}; use an id from the snapshot"}
      record -> {:ok, record}
    end
  end

  defp fetch(what, _id), do: {:error, "#{what}_id must be an integer id from the snapshot"}

  defp load(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp load(_what, _id), do: {:error, :not_found}

  defp get(:student, id), do: People.get_student(id)
  defp get(:session, id), do: Studio.get_session(id)

  defp fetch_credit(id, student, session) when is_integer(id) do
    case Roster.get_credit(id) do
      nil ->
        {:error, "no credit with id #{id}"}

      credit ->
        with :ok <- credit_usable?(credit, student, session), do: {:ok, credit}
    end
  end

  defp fetch_credit(_id, _student, _session), do: {:error, "credit_id must be an integer"}

  defp load_credit(id, student, session) when is_integer(id) do
    case Roster.get_credit(id) do
      nil ->
        {:error, :not_found}

      %{consumed_by_attendance_id: consumed} when not is_nil(consumed) ->
        {:error, :credit_already_consumed}

      credit ->
        case credit_usable?(credit, student, session) do
          :ok -> {:ok, credit}
          error -> error
        end
    end
  end

  defp load_credit(_id, _student, _session), do: {:error, :not_found}

  defp credit_usable?(credit, student, session) do
    available = Roster.available_credits(student.id, session.date)

    cond do
      credit.student_id != student.id ->
        {:error, "credit #{credit.id} does not belong to #{student.display_name}"}

      not Enum.any?(available, &(&1.id == credit.id)) ->
        {:error, "credit #{credit.id} is not available on #{Date.to_iso8601(session.date)}"}

      true ->
        :ok
    end
  end

  defp credit_still_available(credit) do
    if is_nil(credit.consumed_by_attendance_id), do: :ok, else: {:error, :credit_already_consumed}
  end

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_not_booked(roster, student) do
    if Enum.any?(roster, &(&1.student_id == student.id)),
      do: {:error, "#{student.display_name} is already booked in that session"},
      else: :ok
  end

  defp parse_date(nil), do: nil

  defp parse_date(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp short_date(nil), do: ""
  defp short_date(date), do: Fmt.short_date(date)

  defp title("en"), do: "Makeup"
  defp title(_locale), do: "補課"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, _locale),
    do:
      "課堂：#{Fmt.short_date(date)} #{Fmt.weekday(date)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp credit_line(parsed, "en"),
    do:
      "Credit: #{parsed["credit_source"]}" <>
        expiry_text(parsed["credit_expires_on"], "en")

  defp credit_line(parsed, _locale),
    do:
      "補課券：#{credit_source(parsed["credit_source"])}" <>
        expiry_text(parsed["credit_expires_on"], "zh-TW")

  defp expiry_text(nil, "en"), do: " (no expiry)"
  defp expiry_text(nil, _locale), do: "（不會過期）"
  defp expiry_text(iso, "en"), do: " (expires #{iso})"

  defp expiry_text(iso, _locale) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> "（#{Fmt.short_date(date)} 到期）"
      {:error, _} -> "（#{iso} 到期）"
    end
  end

  defp credit_source("package"), do: "方案"
  defp credit_source("cancellation"), do: "停課"
  defp credit_source(other), do: other

  defp roster_change(count, "en") when is_integer(count),
    do: [{"Roster", "#{count}", "#{count + 1}"}]

  defp roster_change(count, _locale) when is_integer(count),
    do: [{"名單", "#{count} 人", "#{count + 1} 人"}]

  defp roster_change(_count, _locale), do: []
end
