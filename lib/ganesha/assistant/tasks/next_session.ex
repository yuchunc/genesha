defmodule Ganesha.Assistant.Tasks.NextSession do
  @moduledoc """
  `next_session` (spec §3.1 #1): today's or the next Session and who is coming.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Roster, Studio}
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "next_session"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Look up today's or the next scheduled Session and who is booked. Use show_card \
      when she should see the roster as a card.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, ctx) do
    case Studio.next_session() do
      nil ->
        {:error, "no scheduled session from today onward"}

      session ->
        roster = Roster.list_for_session(session)

        {:ok,
         %{
           data: Lookup.session_data(session, roster, ctx),
           card: {:session, Lookup.session_payload(session, roster, ctx.locale)}
         }}
    end
  end
end
