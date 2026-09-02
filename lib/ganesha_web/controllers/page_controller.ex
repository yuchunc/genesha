defmodule GaneshaWeb.PageController do
  use GaneshaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
