defmodule Ganesha.Assistant.Tools.TodayRoster do
  @moduledoc "Reads today's scheduled sessions and their roster (spec §4, §5)."
  @behaviour Ganesha.Assistant.Tool

  alias Ganesha.{Clock, Roster, Studio}

  @impl true
  def name, do: "today_roster"

  @impl true
  def schema do
    %{
      name: name(),
      description: "Lists today's scheduled sessions with each session's roster.",
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def call(_input, _thread) do
    today = Clock.today()

    body =
      today
      |> Studio.sessions_between(today)
      |> Enum.map(fn session ->
        %{
          session_id: session.id,
          date: session.date,
          style: session.style,
          roster:
            session
            |> Roster.list_for_session()
            |> Enum.map(&%{student: &1.student.display_name, kind: &1.kind, state: &1.state})
        }
      end)

    {Jason.encode!(body), nil}
  end
end
