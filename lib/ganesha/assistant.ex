defmodule Ganesha.Assistant do
  @moduledoc """
  Threads, messages, and drafts for the LINE AI chat (group listening and
  the teacher's 1:1 assistant). See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Assistant.Message
  alias Ganesha.Assistant.Thread
  alias Ganesha.Repo

  def get_or_create_thread(source_type, source_id) do
    case Repo.get_by(Thread, source_type: source_type, source_id: source_id) do
      %Thread{} = thread ->
        {:ok, thread}

      nil ->
        %Thread{} |> Thread.changeset(%{source_type: source_type, source_id: source_id}) |> Repo.insert()
    end
  end

  def list_messages(%Thread{} = thread) do
    Repo.all(from m in Message, where: m.thread_id == ^thread.id, order_by: m.id)
  end

  def append_message(%Thread{} = thread, role, content, tool_calls, opts \\ []) do
    %Message{}
    |> Message.changeset(%{
      thread_id: thread.id,
      role: role,
      content: content,
      tool_calls: tool_calls,
      line_message_id: opts[:line_message_id]
    })
    |> Repo.insert()
  end
end
