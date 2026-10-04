defmodule Ganesha.Assistant.Tasks.MonthSchedule do
  @moduledoc """
  `month_schedule` (spec §3.1 #2): a month's Sessions with headcounts.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Roster, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "month_schedule"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      List every Session in a calendar month with how many students are booked. \
      Omit month to use the month of today (Taipei).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{
            type: "string",
            description: "First day of the month as ISO 8601, e.g. 2026-10-01"
          }
        }
      }
    }
  end

  @impl true
  def answer(input, ctx) do
    with %Date{} = month <- Lookup.parse_month(input["month"], ctx.today) do
      answer_month(month, ctx)
    end
  end

  defp answer_month(month, ctx) do
    sessions = Studio.sessions_in_month(month)
    counts = Roster.count_by_session(Enum.map(sessions, & &1.id))
    count = &Map.get(counts, &1.id, 0)
    month_label = Format.month_title(month, ctx.locale)

    lines =
      Enum.map(sessions, fn session ->
        "Session #{session.id}: #{Lookup.session_title(session, ctx.locale)}, " <>
          "#{count.(session)} booked" <>
          if(session.state == "cancelled", do: " (cancelled)", else: "")
      end)

    data = Enum.join(["#{month_label}: #{length(sessions)} session(s)" | lines], "; ")

    {:ok, %{data: data}}
  end
end
