defmodule Ganesha.Assistant.Tasks.AddSlot do
  @moduledoc """
  `add_slot` (spec §3.1 #10): creates a weekly Slot and its Sessions for one
  month through `Ganesha.Scheduling.add_weekly_class/2`, the same call the web
  schedule page makes for a recurring class.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Scheduling, Studio}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "add_slot"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Create a new weekly Slot (固定班) and generate its Sessions for one month. This only \
      proposes a Draft; the Slot and Sessions are created when the teacher taps Confirm. \
      Weekday is 1=Monday … 7=Sunday; times are HH:MM:SS. Use month as the first day of the \
      month to generate (ISO 8601).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          weekday: %{type: "integer", minimum: 1, maximum: 7},
          start_time: %{type: "string", description: "HH:MM:SS"},
          end_time: %{type: "string", description: "HH:MM:SS"},
          label: %{type: "string"},
          default_style: %{type: "string", description: "Default style for each Session"},
          month: %{type: "string", description: "First day of the month to generate, ISO 8601"}
        },
        required: ["weekday", "start_time", "end_time", "label", "default_style", "month"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, attrs, month} <- build_attrs(input),
         :ok <- check_slot_free(attrs) do
      parsed =
        Map.merge(attrs, %{
          "start_time" => Time.to_iso8601(attrs["start_time"]),
          "end_time" => Time.to_iso8601(attrs["end_time"]),
          "month" => Date.to_iso8601(month),
          "session_count" => month |> Studio.dates_in_month_on(attrs["weekday"]) |> length()
        })

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  # A new Slot has no Sessions yet, so the count captured at propose cannot
  # drift; only the weekday-and-time clash can appear after propose.
  @impl true
  def apply(parsed, _confirmed_by) do
    with {:ok, attrs, month} <- build_attrs(parsed),
         :ok <- still_slot_free(attrs),
         {:ok, %{slot: slot}} <-
           Scheduling.add_weekly_class(Map.put(attrs, "active", true), month) do
      {:ok, {"Ganesha.Studio.Slot", slot.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    month = parse_date(parsed["month"])

    %{
      title: "#{title(locale)} #{parsed["label"]}",
      lines:
        Enum.reject(
          [
            weekday_line(parsed["weekday"], locale),
            time_line(parse_time(parsed["start_time"]), parse_time(parsed["end_time"]), locale),
            month_line(month, locale),
            style_line(parsed["default_style"], locale)
          ],
          &is_nil/1
        ),
      changes: [{sessions_label(locale), nil, session_count(parsed["session_count"], locale)}],
      web_path: month && "/class/#{month.year}/#{month.month}"
    }
  end

  defp build_attrs(input) do
    with {:ok, weekday} <- parse_weekday(input["weekday"]),
         {:ok, start_time} <- parse_required_time(input["start_time"]),
         {:ok, end_time} <- parse_required_time(input["end_time"]),
         {:ok, label} <- parse_required_string(input["label"], "label"),
         {:ok, default_style} <- parse_required_string(input["default_style"], "default_style"),
         {:ok, month} <- parse_month(input["month"]),
         :ok <- check_time_order(start_time, end_time) do
      {:ok,
       %{
         "weekday" => weekday,
         "start_time" => start_time,
         "end_time" => end_time,
         "label" => label,
         "default_style" => default_style
       }, month}
    end
  end

  defp check_slot_free(attrs) do
    case taken_by(attrs) do
      nil ->
        :ok

      slot ->
        {:error,
         "a slot already holds weekday #{slot.weekday} at #{Time.to_iso8601(slot.start_time)} " <>
           "(#{slot.label}#{if slot.active, do: "", else: ", inactive"}); " <>
           "ask the teacher for another time or weekday"}
    end
  end

  defp still_slot_free(attrs) do
    if taken_by(attrs), do: {:error, :slot_taken}, else: :ok
  end

  # Slots are unique on weekday + start_time, active or not.
  defp taken_by(%{"weekday" => weekday, "start_time" => start_time}) do
    Enum.find(Studio.list_slots(), &(&1.weekday == weekday and &1.start_time == start_time))
  end

  defp parse_weekday(n) when is_integer(n) and n in 1..7, do: {:ok, n}
  defp parse_weekday(_n), do: {:error, "weekday must be 1 (Monday) through 7 (Sunday)"}

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, Date.beginning_of_month(date)}
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  defp parse_required_time(text) do
    case parse_time(text) do
      nil -> {:error, "start_time and end_time must be HH:MM:SS like 19:00:00"}
      time -> {:ok, time}
    end
  end

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

  defp title("en"), do: "New weekly class"
  defp title(_locale), do: "固定班次"

  defp weekday_line(weekday, "en") when weekday in 1..7, do: "Weekday: #{weekday_en(weekday)}"
  defp weekday_line(weekday, _locale) when weekday in 1..7, do: "星期：#{Fmt.weekday(weekday)}"
  defp weekday_line(_weekday, _locale), do: nil

  # 2024-01-01 is a Monday, so weekday 1..7 maps onto Mon..Sun.
  defp weekday_en(weekday), do: ~D[2024-01-01] |> Date.add(weekday - 1) |> Calendar.strftime("%a")

  defp time_line(start, stop, _locale) when is_nil(start) or is_nil(stop), do: nil
  defp time_line(start, stop, "en"), do: "Time: #{Fmt.time_range(start, stop)}"
  defp time_line(start, stop, _locale), do: "時間：#{Fmt.time_range(start, stop)}"

  defp month_line(nil, _locale), do: nil
  defp month_line(month, "en"), do: "Month: #{Format.month_title(month, "en")}"
  defp month_line(month, locale), do: "月份：#{Format.month_title(month, locale)}"

  defp style_line(style, _locale) when style in [nil, ""], do: nil
  defp style_line(style, "en"), do: "Style: #{style}"
  defp style_line(style, _locale), do: "課型：#{style}"

  defp sessions_label("en"), do: "Sessions"
  defp sessions_label(_locale), do: "課堂"

  defp session_count(count, "en") when is_integer(count), do: "#{count} scheduled"
  defp session_count(count, _locale) when is_integer(count), do: "排 #{count} 堂"
  defp session_count(_count, _locale), do: "—"
end
