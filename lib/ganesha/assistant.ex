defmodule Ganesha.Assistant do
  @moduledoc """
  Threads, messages, and drafts for the LINE AI chat (group listening and
  the teacher's 1:1 assistant). See
  docs/superpowers/specs/2026-09-11-line-ai-chat-design.md.
  """

  import Ecto.Query, warn: false
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
end
