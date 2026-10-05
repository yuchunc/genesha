defmodule Ganesha.Assistant.Tasks.BlockAccount do
  @moduledoc """
  `block_account` (spec 2026-10-05-line-group-blocklist-design.md §3): stop
  reading a LINE group, or one sender in every group. Teacher chat only;
  applies through `Ganesha.Line.block_account/1` on Confirm (ADR 0001).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Line}

  @kinds ~w(group sender)

  @impl true
  def name, do: "block_account"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Stop reading a LINE group, or one person's messages in every group (封鎖). This \
      only proposes a Draft; the block starts when the teacher taps Confirm. Take \
      line_id from listening, never from a name you guessed.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          kind: %{type: "string", enum: @kinds},
          line_id: %{
            type: "string",
            description: "Group id (C…) or sender id (U…) from listening"
          }
        },
        required: ["kind", "line_id"]
      }
    }
  end

  @impl true
  def propose(%{"kind" => kind, "line_id" => line_id}, _ctx)
      when kind in @kinds and is_binary(line_id) do
    with {:ok, label} <- resolve(kind, line_id),
         :ok <- not_blocked(kind, line_id) do
      {:ok, %{student_id: nil, parsed: %{"kind" => kind, "line_id" => line_id, "label" => label}}}
    end
  end

  def propose(_input, _ctx),
    do: {:error, ~s(kind must be "group" or "sender", and line_id an id from listening)}

  @impl true
  def apply(%{"kind" => kind, "line_id" => line_id, "label" => label}, _confirmed_by) do
    with {:ok, blocked} <- Line.block_account(%{kind: kind, line_id: line_id, label: label}) do
      {:ok, {"Ganesha.Line.BlockedAccount", blocked.id}}
    end
  end

  @impl true
  def summary(%{"kind" => "sender", "label" => label}, "en"),
    do: "Block #{label}: their messages in every group will be ignored"

  def summary(%{"kind" => "sender", "label" => label}, _locale),
    do: "封鎖 #{label}：之後所有群組中這個人的訊息都不再讀取"

  def summary(%{"kind" => "group", "label" => label}, "en"),
    do: ~s(Block group "#{label}": stop reading this group)

  def summary(%{"kind" => "group", "label" => label}, _locale),
    do: "封鎖群組「#{label}」：之後不再讀取這個群組"

  defp resolve("group", group_id) do
    if Assistant.get_group_thread(group_id),
      do: {:ok, Line.group_name(group_id)},
      else: {:error, "No group with id #{group_id}. Call listening for the groups the bot reads."}
  end

  defp resolve("sender", user_id) do
    cond do
      Line.teacher?(user_id) ->
        {:error, "#{user_id} is a teacher; teachers' group posts are already ignored."}

      sender = Assistant.find_group_sender(user_id) ->
        {:ok, sender.sender_name || user_id}

      true ->
        {:error, "No group sender with id #{user_id}. Call listening for recent senders."}
    end
  end

  defp not_blocked(kind, line_id) do
    if Line.blocked?(kind, line_id),
      do: {:error, "#{line_id} is already blocked."},
      else: :ok
  end
end
