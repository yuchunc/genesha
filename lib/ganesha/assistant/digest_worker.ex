defmodule Ganesha.Assistant.DigestWorker do
  @moduledoc """
  Nightly at 00:30 Asia/Taipei (`30 16 * * *` UTC): fills every Teacher
  chat's missing daily and weekly digests (spec §6.4). One thread failing is
  logged and skipped; the next night fills the gap (spec §7). The Group chat
  and Student chats get no digests (ADR 0003).
  """
  use Oban.Worker, queue: :default

  require Logger

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.Memory

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Clock.today()

    for thread <- Assistant.list_threads("teacher") do
      try do
        Memory.write_missing_digests(thread, today)
      rescue
        exception ->
          Logger.error(
            "digests for thread #{thread.id} failed: " <>
              Exception.format(:error, exception, __STACKTRACE__)
          )
      end
    end

    :ok
  end
end
