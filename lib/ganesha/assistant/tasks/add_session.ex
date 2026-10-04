defmodule Ganesha.Assistant.Tasks.AddSession do
  @moduledoc """
  `add_session` (spec §3.1 #9): creates one standalone Session through
  `Ganesha.Studio.create_session/1`, the same call the web schedule page uses
  for a one-off class.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Summary
  alias Ganesha.Studio.Session
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "add_session"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Schedule one standalone Session on a date (not a recurring Slot). This only \
      proposes a Draft; the Session is created when the teacher taps Confirm. Use ISO \
      dates and HH:MM:SS times.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          date: %{type: "string", description: "ISO 8601 date"},
          start_time: %{type: "string", description: "HH:MM:SS"},
          end_time: %{type: "string", description: "HH:MM:SS"},
          label: %{type: "string", description: "Class name shown to students"},
          style: %{type: "string", description: "Style (課型) for this Session"}
        },
        required: ["date", "start_time", "end_time", "label", "style"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, attrs} <- build_attrs(input),
         :ok <- validate_session(attrs),
         :ok <- check_no_duplicate(attrs) do
      parsed =
        Map.merge(attrs, %{
          "date" => Date.to_iso8601(attrs["date"]),
          "start_time" => Time.to_iso8601(attrs["start_time"]),
          "end_time" => Time.to_iso8601(attrs["end_time"])
        })

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    with {:ok, attrs} <- build_attrs(parsed),
         :ok <- still_no_duplicate(attrs),
         {:ok, session} <- Studio.create_session(create_attrs(attrs)) do
      {:ok, {"Ganesha.Studio.Session", session.id}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    session =
      Summary.words([
        Summary.day(parsed["date"], locale),
        Summary.time_range(parsed["start_time"], parsed["end_time"]),
        parsed["label"]
      ])

    style = Summary.paren([parsed["style"]], locale)
    if locale == "en", do: "Add a class: #{session}" <> style, else: "加開 #{session}" <> style
  end

  @impl true
  def describe(parsed, locale) do
    date = parse_date(parsed["date"])

    %{
      title: "#{title(locale)} #{parsed["label"]}",
      lines:
        Enum.reject(
          [
            date_line(date, locale),
            time_line(parse_time(parsed["start_time"]), parse_time(parsed["end_time"]), locale),
            style_line(parsed["style"], locale)
          ],
          &is_nil/1
        ),
      changes: [{session_label(locale), nil, parsed["label"]}],
      web_path: month_path(date)
    }
  end

  defp build_attrs(input) do
    with {:ok, date} <- parse_required_date(input["date"]),
         {:ok, start_time} <- parse_required_time(input["start_time"]),
         {:ok, end_time} <- parse_required_time(input["end_time"]),
         {:ok, label} <- parse_required_string(input["label"], "label"),
         {:ok, style} <- parse_required_string(input["style"], "style"),
         :ok <- check_time_order(start_time, end_time) do
      {:ok,
       %{
         "date" => date,
         "start_time" => start_time,
         "end_time" => end_time,
         "label" => label,
         "style" => style
       }}
    end
  end

  # The same attrs `apply/2` hands to `Studio.create_session/1`, so a Draft
  # the Session changeset would reject never reaches the teacher.
  defp create_attrs(attrs), do: Map.merge(attrs, %{"state" => "scheduled", "slot_id" => nil})

  defp validate_session(attrs) do
    case %Session{}
         |> Session.changeset(create_attrs(attrs))
         |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _session} ->
        :ok

      {:error, changeset} ->
        {:error, "invalid session: " <> Assistant.format_changeset_errors(changeset)}
    end
  end

  defp check_no_duplicate(attrs) do
    if duplicate?(attrs),
      do:
        {:error,
         "#{attrs["label"]} on #{attrs["date"]} at #{attrs["start_time"]} is already scheduled"},
      else: :ok
  end

  defp still_no_duplicate(attrs) do
    if duplicate?(attrs), do: {:error, :duplicate_session}, else: :ok
  end

  defp duplicate?(%{"date" => date, "start_time" => start_time, "label" => label}) do
    date
    |> Studio.sessions_in_month()
    |> Enum.any?(fn session ->
      session.slot_id == nil and session.date == date and session.start_time == start_time and
        session.label == label
    end)
  end

  defp parse_required_date(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "date must be an ISO 8601 date like 2026-10-20"}
    end
  end

  defp parse_required_date(_text), do: {:error, "date must be an ISO 8601 date like 2026-10-20"}

  defp parse_required_time(text) do
    case parse_time(text) do
      nil -> {:error, "start_time and end_time must be HH:MM:SS like 19:00:00"}
      time -> {:ok, time}
    end
  end

  defp parse_required_string(text, field) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, "#{field} must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_required_string(_text, field), do: {:error, "#{field} must be a string"}

  defp check_time_order(start_time, end_time) do
    if Time.compare(start_time, end_time) == :lt,
      do: :ok,
      else: {:error, "end_time must be after start_time"}
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_date(_iso), do: nil

  # Accepts "HH:MM" too: the model often drops the seconds.
  defp parse_time(text) when is_binary(text) do
    case Time.from_iso8601(normalize_time(text)) do
      {:ok, time} -> time
      {:error, _} -> nil
    end
  end

  defp parse_time(_text), do: nil

  defp normalize_time(hm) when byte_size(hm) == 5, do: hm <> ":00"
  defp normalize_time(other), do: other

  defp month_path(nil), do: nil
  defp month_path(%Date{} = date), do: "/class/#{date.year}/#{date.month}"

  defp title("en"), do: "Add session"
  defp title(_locale), do: "排課"

  defp session_label("en"), do: "Session"
  defp session_label(_locale), do: "課堂"

  defp date_line(nil, _locale), do: nil
  defp date_line(date, "en"), do: "Date: #{Format.session_day(date, "en")}"
  defp date_line(date, locale), do: "日期：#{Format.session_day(date, locale)}"

  defp time_line(start, stop, _locale) when is_nil(start) or is_nil(stop), do: nil
  defp time_line(start, stop, "en"), do: "Time: #{Fmt.time_range(start, stop)}"
  defp time_line(start, stop, _locale), do: "時間：#{Fmt.time_range(start, stop)}"

  defp style_line(style, _locale) when style in [nil, ""], do: nil
  defp style_line(style, "en"), do: "Style: #{style}"
  defp style_line(style, _locale), do: "課型：#{style}"
end
