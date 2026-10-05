defmodule Ganesha.Line.Client.Mock do
  @moduledoc """
  Test-only `Ganesha.Line.ClientBehaviour`. Records calls in the calling
  process's dictionary — the group-thread safety test (Task 17) asserts on
  `calls/0` to prove the code path never sends anything into the group.
  """
  @behaviour Ganesha.Line.ClientBehaviour

  @impl true
  def reply(reply_token, messages) do
    record(:reply, {reply_token, messages})
    :ok
  end

  @impl true
  def push(to, messages) do
    record(:push, {to, messages})
    :ok
  end

  @impl true
  def loading(chat_id, seconds) do
    record(:loading, {chat_id, seconds})
    :ok
  end

  @impl true
  def validate_reply(messages) do
    record(:validate_reply, messages)
    :ok
  end

  @impl true
  def get_group_member(group_id, user_id) do
    record_lookup({:group_member, group_id, user_id})
    Process.get(:line_client_mock_group_member, {:ok, %{"displayName" => "測試學生"}})
  end

  @impl true
  def get_group_summary(group_id) do
    record_lookup({:group_summary, group_id})
    Process.get(:line_client_mock_group_summary, {:ok, %{"groupName" => "測試群組"}})
  end

  @doc "Read-only lookups, kept out of `calls/0` so the never-sends assertions stay exact."
  def lookups, do: Process.get(:line_client_mock_lookups, []) |> Enum.reverse()

  def calls, do: Process.get(:line_client_mock_calls, []) |> Enum.reverse()

  defp record(kind, payload) do
    Process.put(:line_client_mock_calls, [
      {kind, payload} | Process.get(:line_client_mock_calls, [])
    ])
  end

  defp record_lookup(lookup) do
    Process.put(:line_client_mock_lookups, [lookup | Process.get(:line_client_mock_lookups, [])])
  end
end
