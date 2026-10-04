defmodule Ganesha.Assistant.Tasks.CopyMonth do
  @moduledoc """
  `copy_month` (spec §3.1 #11): copies every active Slot's schedule into a
  month through `Ganesha.Studio.copy_month/1`, the same call the web month
  page's copy prompt uses.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Studio
  alias Ganesha.Assistant.Summary

  @impl true
  def name, do: "copy_month"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Copy every active weekly Slot's Sessions into a month (same as the web "copy last \
      month's schedule" prompt). This only proposes a Draft; Sessions are created when the \
      teacher taps Confirm. Pass month as the first day of the target month (ISO 8601).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{type: "string", description: "Target month, ISO 8601 date like 2026-10-01"}
        },
        required: ["month"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, month} <- parse_month(input["month"]),
         {:ok, slots} <- active_slots() do
      case new_sessions(slots, month) do
        [] ->
          {:error,
           "every active slot already has all its sessions in #{Date.to_iso8601(month)}; " <>
             "there is nothing to copy"}

        new_sessions ->
          {:ok,
           %{
             student_id: nil,
             parsed: %{
               "month" => Date.to_iso8601(month),
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
         :ok <- same_sessions(month, parsed["new_sessions"]),
         {:ok, _created} <- Studio.copy_month(month) do
      {:ok, {nil, nil}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    month = Summary.month_name(parsed["month"], locale)
    count = parsed["session_count"] || 0

    if locale == "en",
      do: "Schedule #{month} from the weekly classes: #{count} sessions",
      else: "照固定班排 #{month} 課表，共 #{count} 堂"
  end

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, Date.beginning_of_month(date)}
      {:error, _} -> {:error, "month must be an ISO 8601 date like 2026-10-01"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be an ISO 8601 date like 2026-10-01"}

  defp active_slots do
    case Studio.list_active_slots() do
      [] -> {:error, "there are no active slots to copy; add a weekly slot first"}
      slots -> {:ok, slots}
    end
  end

  # The Sessions `Studio.copy_month/1` would create, as sorted
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
  defp same_sessions(month, proposed) do
    if new_sessions(Studio.list_active_slots(), month) == proposed,
      do: :ok,
      else: {:error, :schedule_changed}
  end
end
