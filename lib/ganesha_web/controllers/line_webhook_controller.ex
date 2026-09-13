defmodule GaneshaWeb.LineWebhookController do
  use GaneshaWeb, :controller

  alias Ganesha.Line

  @doc """
  Verified upstream by `Ganesha.Line.VerifySignaturePlug`. Always answers
  200 once persisted — LINE redelivers on anything else (spec §2, original
  design §5.1, §5.7).
  """
  def create(conn, %{"events" => events}) do
    Enum.each(events, &Line.record_event/1)
    send_resp(conn, 200, "")
  end

  def create(conn, _params), do: send_resp(conn, 200, "")
end
