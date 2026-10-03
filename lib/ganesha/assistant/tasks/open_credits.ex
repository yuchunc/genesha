defmodule Ganesha.Assistant.Tasks.OpenCredits do
  @moduledoc """
  `open_credits` (spec §3.1 #6): open and expiring makeup Credits.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Reporting
  alias Ganesha.Assistant.Format

  @impl true
  def name, do: "open_credits"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Every unspent makeup Credit in the studio, soonest expiry first. Use show_card \
      for the credits card.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, ctx) do
    credits = Reporting.open_credits(ctx.today)
    month_end = Date.end_of_month(ctx.today)

    # open_credits/1 already drops expired ones, so a dated credit is expiring
    # this month exactly when it lapses on or before the month's last day.
    expiring =
      Enum.count(credits, &(&1.expires_on && Date.compare(&1.expires_on, month_end) != :gt))

    payload = %{
      "count" => length(credits),
      "expiring_count" => expiring,
      "rows" =>
        Enum.map(credits, fn credit ->
          %{
            "student" => credit.student.display_name,
            "source" => credit.source,
            "expires" => credit.expires_on && Format.session_day(credit.expires_on, ctx.locale)
          }
        end)
    }

    data =
      "#{length(credits)} open credit(s)" <>
        if(expiring > 0, do: ", #{expiring} expiring this month", else: "") <>
        credits_data(credits, ctx.locale)

    {:ok, %{data: data, card: {:credits, payload}}}
  end

  defp credits_data([], _locale), do: ""

  defp credits_data(credits, locale) do
    ": " <>
      Enum.map_join(credits, "; ", fn credit ->
        expiry =
          if credit.expires_on,
            do: "expires #{Format.session_day(credit.expires_on, locale)}",
            else: "no expiry"

        "#{credit.student.display_name} (student #{credit.student_id}) #{credit.source}, #{expiry}"
      end)
  end
end
