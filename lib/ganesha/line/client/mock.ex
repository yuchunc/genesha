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
  def get_group_member(_group_id, _user_id), do: {:ok, %{"displayName" => "測試學生"}}

  def calls, do: Process.get(:line_client_mock_calls, []) |> Enum.reverse()

  defp record(kind, payload) do
    Process.put(:line_client_mock_calls, [{kind, payload} | Process.get(:line_client_mock_calls, [])])
  end
end
