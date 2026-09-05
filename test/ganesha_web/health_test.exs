defmodule GaneshaWeb.HealthTest do
  use GaneshaWeb.ConnCase, async: true

  test "the health endpoint is public and returns ok", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert response(conn, 200) == "ok"
  end
end
