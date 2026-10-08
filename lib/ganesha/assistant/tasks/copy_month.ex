defmodule Ganesha.Assistant.Tasks.CopyMonth do
  @moduledoc """
  `copy_month` (spec §3.1 #11): copies the active Slots' schedule into a
  month through `Ganesha.Studio.copy_month/2`, the same call the web month
  page's copy prompt uses. `slot_ids` narrows it to the weekly classes she
  named; without it every active Slot is copied, as on the web.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Studio
  alias Ganesha.Assistant.Summary
  alias GaneshaWeb.Fmt

  @impl true
  def name, do: "copy_month"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Generate a month's Sessions from weekly Slots (固定班), like the web "copy last \
      month's schedule" prompt. This only proposes a Draft; Sessions are created when the \
      teacher taps Confirm. Pass month as the first day of the target month (ISO 8601). \
      Leave slot_ids out only when she wants every weekly class; to open just some of them, \
      pass their slot ids from the snapshot. One call per month.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{type: "string", description: "Target month, ISO 8601 date like 2026-10-01"},
          slot_ids: %{
            type: "array",
            items: %{type: "integer"},
            description: "Only these active Slots; omit for every active Slot"
          }
        },
        required: ["month"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, month} <- parse_month(input["month"]),
         {:ok, slots} <- pick_slots(input["slot_ids"]) do
      case new_sessions(slots, month) do
        [] ->
          {:error,
           "these slots already have all their sessions in #{Date.to_iso8601(month)}; " <>
             "there is nothing to copy"}

        new_sessions ->
          {:ok,
           %{
             student_id: nil,
             parsed: %{
               "month" => Date.to_iso8601(month),
               "slot_ids" => input["slot_ids"] && Enum.map(slots, & &1.id),
               "slots" => input["slot_ids"] && Enum.map(slots, &slot_display/1),
               "session_count" => length(new_sessions),
               "new_sessions" => new_sessions
             }
           }}
      end
    end
  end

  # Copying creates many Sessions and no single record, so the Draft links none.
  @impl true
  def apply(parsed, _confirmed_by) do
    with {:ok, month} <- parse_month(parsed["month"]),
         {:ok, slots} <- still_active(parsed["slot_ids"]),
         :ok <- same_sessions(slots, month, parsed["new_sessions"]),
         {:ok, _created} <- Studio.copy_month(month, slots) do
      {:ok, {nil, nil}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    month = Summary.month_name(parsed["month"], locale)
    count = parsed["session_count"] || 0
    classes = Summary.paren(Enum.map(parsed["slots"] || [], &slot_name(&1, locale)), locale)

    if locale == "en",
      do: "Schedule #{month} from the weekly classes#{classes}: #{count} sessions",
      else: "照固定班#{classes}排 #{month} 課表，共 #{count} 堂"
  end

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, Date.beginning_of_month(date)}
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  defp pick_slots(nil) do
    case Studio.list_active_slots() do
      [] -> {:error, "there are no active slots to copy; add a weekly slot first"}
      slots -> {:ok, slots}
    end
  end

  defp pick_slots([_ | _] = ids) do
    if Enum.all?(ids, &is_integer/1) do
      active = Map.new(Studio.list_active_slots(), &{&1.id, &1})

      case Enum.reject(Enum.uniq(ids), &Map.has_key?(active, &1)) do
        [] ->
          {:ok,
           active |> Map.take(ids) |> Map.values() |> Enum.sort_by(&{&1.weekday, &1.start_time})}

        unknown ->
          {:error,
           "no active slot with id #{Enum.join(unknown, ", ")}; use active slot ids from the snapshot"}
      end
    else
      {:error, slot_ids_invalid()}
    end
  end

  defp pick_slots(_ids), do: {:error, slot_ids_invalid()}

  defp slot_ids_invalid,
    do: "slot_ids must be a non-empty list of slot ids from the snapshot, or left out"

  # A Slot she picked that was deactivated since propose changes what she confirmed.
  defp still_active(nil), do: {:ok, Studio.list_active_slots()}

  defp still_active(ids) do
    case pick_slots(ids) do
      {:ok, slots} -> {:ok, slots}
      {:error, _} -> {:error, :schedule_changed}
    end
  end

  defp slot_display(slot) do
    %{
      "weekday" => slot.weekday,
      "time" => Fmt.time_range(slot.start_time, slot.end_time),
      "title" => Fmt.slot_title(slot.label)
    }
  end

  defp slot_name(slot, locale),
    do: Summary.words([Summary.weekday(slot["weekday"], locale), slot["time"], slot["title"]])

  # The Sessions `Studio.copy_month/2` would create, as sorted
  # `[slot_id, iso_date]` pairs (lists, so they survive the Draft's JSON).
  defp new_sessions(slots, month) do
    slots
    |> Enum.flat_map(fn slot ->
      Enum.map(Studio.missing_dates(slot, month), &[slot.id, Date.to_iso8601(&1)])
    end)
    |> Enum.sort()
  end

  # The teacher confirmed these exact Sessions; a Slot or Session change since
  # propose would make the copy create different ones, even at the same count.
  defp same_sessions(slots, month, proposed) do
    if new_sessions(slots, month) == proposed,
      do: :ok,
      else: {:error, :schedule_changed}
  end
end
