defmodule Ganesha.Assistant.Tasks.Listening do
  @moduledoc """
  Lookup task `listening` (spec 2026-10-05-line-group-blocklist-design.md §3):
  the groups the bot reads, who has posted in each recently, and the
  blocklist. Teacher chat only; the ids it returns are what `block_account`
  and `unblock_account` take.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Clock, Line}

  @senders_per_group 30

  @impl true
  def name, do: "listening"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      The LINE groups you read, who has posted in each recently, and who is blocked. \
      Call it before block_account or unblock_account to get the exact group or sender \
      id, and when the teacher asks which groups or people you listen to.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, _ctx) do
    blocked = Line.list_blocked_accounts()
    blocked_ids = MapSet.new(blocked, &{&1.kind, &1.line_id})

    {:ok, %{data: groups_section(blocked_ids) <> "\n\n" <> blocked_section(blocked)}}
  end

  defp groups_section(blocked_ids) do
    case Assistant.list_threads("group") do
      [] -> "Groups: none yet. No group has sent the bot a message."
      threads -> Enum.map_join(threads, "\n\n", &group_section(&1, blocked_ids))
    end
  end

  defp group_section(thread, blocked_ids) do
    status = if {"group", thread.source_id} in blocked_ids, do: "blocked", else: "listening"
    header = "Group #{Line.group_name(thread.source_id)} (id #{thread.source_id}), #{status}"

    senders =
      case Assistant.group_senders(thread, @senders_per_group) do
        [] -> ["- none"]
        senders -> Enum.map(senders, &sender_line(&1, blocked_ids))
      end

    Enum.join([header, "Recent senders:" | senders], "\n")
  end

  defp sender_line(sender, blocked_ids) do
    blocked = if {"sender", sender.sender_id} in blocked_ids, do: ", blocked", else: ""
    name = sender.sender_name || "(name unknown)"

    "- #{name} (id #{sender.sender_id}), last seen #{taipei_minute(sender.last_seen_at)}#{blocked}"
  end

  defp blocked_section([]), do: "Blocked: nobody."

  defp blocked_section(blocked) do
    lines =
      Enum.map(blocked, fn b ->
        "- #{b.kind} #{b.label} (id #{b.line_id}), since #{Clock.to_taipei_date(b.inserted_at)}"
      end)

    Enum.join(["Blocked:" | lines], "\n")
  end

  defp taipei_minute(utc) do
    utc |> Clock.to_taipei_naive() |> NaiveDateTime.to_string() |> String.slice(0, 16)
  end
end
