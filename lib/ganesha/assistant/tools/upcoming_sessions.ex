defmodule Ganesha.Assistant.Tools.UpcomingSessions do
  @moduledoc "Reads scheduled sessions in the next N days, default 7 (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Clock, Studio}

  @impl true
  def name, do: "upcoming_sessions"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Lists scheduled sessions in the next N days (default 7).",
      input_schema: %{type: "object", properties: %{days: %{type: "integer"}}}
    }
  end

  @impl true
  def call(input, _thread) do
    days = Map.get(input, "days", 7)
    today = Clock.today()

    body =
      today
      |> Studio.sessions_between(Date.add(today, days))
      |> Enum.map(&%{session_id: &1.id, date: &1.date, style: &1.style})

    {Jason.encode!(body), nil}
  end
end
