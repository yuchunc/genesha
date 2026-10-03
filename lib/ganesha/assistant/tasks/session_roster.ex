defmodule Ganesha.Assistant.Tasks.SessionRoster do
  @moduledoc """
  `session_roster` (spec §3.1 #3): one Session's roster.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Roster
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "session_roster"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Look up who is booked in one Session. Pass session_id from the snapshot. \
      Use show_card to show the roster card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{session_id: %{type: "integer"}},
        required: ["session_id"]
      }
    }
  end

  @impl true
  def answer(%{"session_id" => session_id}, ctx) do
    with {:ok, session} <- Lookup.fetch_session(session_id) do
      roster = Roster.list_for_session(session)

      {:ok,
       %{
         data: Lookup.session_data(session, roster, ctx),
         card: {:session, Lookup.session_payload(session, roster, ctx.locale)}
       }}
    end
  end

  def answer(_input, _ctx), do: {:error, "session_id must be a session id from the snapshot"}
end
