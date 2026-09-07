defmodule GaneshaWeb.RegistrationClosedTest do
  use GaneshaWeb.ConnCase, async: true

  test "the registration page does not exist", %{conn: conn} do
    conn = %{conn | path_info: ["users", "register"], request_path: "/users/register"}

    assert_raise Phoenix.Router.NoRouteError, fn ->
      GaneshaWeb.Router.call(conn, GaneshaWeb.Router.init([]))
    end
  end
end
