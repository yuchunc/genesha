defmodule GaneshaWeb.LineWebhookController do
  use GaneshaWeb, :controller

  alias Ganesha.Line

  @doc """
  Verified upstream by `Ganesha.Line.VerifySignaturePlug`. Answers 200 once
  every event is persisted (a duplicate counts), and 500 when any failed to
  store, so LINE redelivers the batch; the stored ones dedupe on
  `webhookEventId` (spec 2026-10-07 §5, original design §5.1, §5.7).
  """
  def create(conn, %{"events" => events}) do
    results = Enum.map(events, &Line.record_event/1)
    status = if Enum.all?(results, &(&1 == :ok)), do: 200, else: 500
    send_resp(conn, status, "")
  end

  def create(conn, _params), do: send_resp(conn, 200, "")
end
