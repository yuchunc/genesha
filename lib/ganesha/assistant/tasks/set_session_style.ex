defmodule Ganesha.Assistant.Tasks.SetSessionStyle do
  @moduledoc """
  `set_session_style` (spec §3.1 #8): changes one Session's style through
  `Ganesha.Studio.set_style/2`, the same call the web month page makes.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Studio
  alias Ganesha.Assistant.Summary
  alias Ganesha.Assistant.Tasks.Lookup
  alias GaneshaWeb.Fmt

  @apply_keys ~w(session_id style)

  @impl true
  def name, do: "set_session_style"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Change the style (課型) of one scheduled Session for a single date. This only \
      proposes a Draft; the style changes when the teacher taps Confirm. Use a session id \
      from the studio snapshot.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          session_id: %{type: "integer"},
          style: %{type: "string", description: "The new style for this Session only"}
        },
        required: ["session_id", "style"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, session} <- Lookup.fetch_session(input["session_id"]),
         :ok <- check_scheduled(session),
         {:ok, style} <- check_style(input["style"]) do
      parsed = %{
        "session_id" => session.id,
        "style" => style,
        "before_style" => session.style,
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session)
      }

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, session} <- Lookup.load_session(attrs["session_id"]),
         :ok <- still_scheduled(session),
         :ok <- same_style(session, parsed["before_style"]),
         {:ok, updated} <- Studio.set_style(session, attrs["style"]) do
      {:ok, {"Ganesha.Studio.Session", updated.id}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    session =
      Summary.words([
        Summary.day(parsed["session_date"], locale),
        parsed["session_time"],
        parsed["session_label"]
      ])

    if locale == "en",
      do: "Change #{session} to #{parsed["style"]} (was #{parsed["before_style"]})",
      else: "#{session} 改上 #{parsed["style"]}（原本 #{parsed["before_style"]}）"
  end

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_style(style) when is_binary(style) do
    case String.trim(style) do
      "" -> {:error, "style must not be blank"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp check_style(_style), do: {:error, "style must be a string"}

  # The card showed `before → after`; if someone changed the style since,
  # the teacher must see a fresh card rather than overwrite it blind.
  defp same_style(%{style: current}, before) when is_binary(before) do
    if current == before, do: :ok, else: {:error, :style_changed}
  end

  defp same_style(_session, _before), do: {:error, :style_changed}
end
