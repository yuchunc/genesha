defmodule GaneshaWeb.HealthController do
  use GaneshaWeb, :controller

  @doc "Unauthenticated liveness probe for the platform health check."
  def index(conn, _params), do: send_resp(conn, 200, "ok")
end
