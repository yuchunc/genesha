defmodule Ganesha.Assistant.Tasks.CancelSession do
  @moduledoc """
  `cancel_session` (spec §3.1 #7): cancels one Session and issues a Credit to
  everyone seated in it through `Ganesha.Scheduling.cancel_session/2`, the
  same call the web month page makes. A reason is required: students see it
  and it travels on their Credits, so the model must ask rather than invent.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Roster, Scheduling}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup
  alias GaneshaWeb.Fmt

  @apply_keys ~w(session_id reason)

  @impl true
  def name, do: "cancel_session"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Cancel one scheduled Session; every student booked in it gets a makeup Credit \
      (補課券). This only proposes a Draft; the Session is cancelled when the teacher taps \
      Confirm. A reason is required and students see it: use her words (颱風假, 老師生病). \
      If she has not said why, ask her first; never invent a reason. Use a session id from \
      the studio snapshot.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          session_id: %{type: "integer"},
          reason: %{
            type: "string",
            description: "Why the Session is cancelled, in the teacher's words"
          }
        },
        required: ["session_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, session} <- Lookup.fetch_session(input["session_id"]),
         :ok <- check_scheduled(session),
         {:ok, reason} <- check_reason(input["reason"]) do
      parsed = %{
        "session_id" => session.id,
        "reason" => reason,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "credit_count" => Roster.cancellation_credit_count(session)
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, session} <- Lookup.load_session(attrs["session_id"]),
         :ok <- still_scheduled(session),
         :ok <- same_credit_count(session, parsed["credit_count"]),
         {:ok, %{session: cancelled}} <- Scheduling.cancel_session(session, attrs["reason"]) do
      {:ok, {"Ganesha.Studio.Session", cancelled.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["session_date"])

    %{
      title: "#{title(locale)} #{short_date(date)} #{parsed["session_label"]}",
      lines:
        Enum.reject(
          [session_line(parsed, date, locale), reason_line(parsed["reason"], locale)],
          &is_nil/1
        ),
      changes: [state_change(locale) | credit_change(parsed["credit_count"], locale)],
      web_path: parsed["session_id"] && "/sessions/#{parsed["session_id"]}"
    }
  end

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is already cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_not_scheduled}

  defp check_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> missing_reason()
      trimmed -> {:ok, trimmed}
    end
  end

  defp check_reason(_reason), do: missing_reason()

  defp missing_reason,
    do:
      {:error,
       "a cancellation needs a reason, and students will see it; " <>
         "ask the teacher why the Session is cancelled"}

  # The card promised this many Credits; a roster change since then would
  # issue a different number, so the teacher must see a fresh card.
  defp same_credit_count(session, count) do
    if Roster.cancellation_credit_count(session) == count,
      do: :ok,
      else: {:error, :roster_changed}
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  defp short_date(nil), do: ""
  defp short_date(date), do: Fmt.short_date(date)

  defp title("en"), do: "Cancel"
  defp title(_locale), do: "停課"

  defp session_line(_parsed, nil, _locale), do: nil

  defp session_line(parsed, date, "en"),
    do:
      "Session: #{Format.session_day(date, "en")} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp session_line(parsed, date, locale),
    do:
      "課堂：#{Format.session_day(date, locale)} " <>
        "#{parsed["session_label"]} #{parsed["session_time"]}"

  defp reason_line(reason, _locale) when reason in [nil, ""], do: nil
  defp reason_line(reason, "en"), do: "Reason: #{reason}"
  defp reason_line(reason, _locale), do: "原因：#{reason}"

  defp state_change("en"), do: {"Status", "Scheduled", "Cancelled"}
  defp state_change(_locale), do: {"狀態", "上課", "停課"}

  defp credit_change(count, "en") when is_integer(count),
    do: [{"Makeup credits", nil, "#{count} issued"}]

  defp credit_change(count, _locale) when is_integer(count),
    do: [{"補課券", nil, "發出 #{count} 張"}]

  defp credit_change(_count, _locale), do: []
end
