defmodule GaneshaWeb.HealthController do
  use GaneshaWeb, :controller

  @doc """
  Unauthenticated liveness+readiness probe for the platform health check.

  Touches the database rather than answering unconditionally: a machine
  whose volume failed to mount or whose SQLite file is unwritable would
  otherwise report healthy while every real page 500s, and Fly would keep
  routing traffic to it instead of rolling the deploy back.
  """
  def index(conn, _params) do
    Ganesha.Repo.query!("select 1")
    send_resp(conn, 200, "ok")
  end
end
