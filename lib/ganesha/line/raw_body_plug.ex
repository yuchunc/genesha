defmodule Ganesha.Line.RawBodyPlug do
  @moduledoc """
  A `Plug.Parsers` `:body_reader` that caches the exact bytes read from the
  request into `conn.assigns.raw_body` before parsing consumes them, so
  `VerifySignaturePlug` can verify against the untouched body afterward.
  Configured endpoint-wide in `GaneshaWeb.Endpoint`, because `Plug.Parsers`
  itself runs once, before the router decides which route it is.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache(conn, body)}
      {:more, body, conn} -> {:more, body, cache(conn, body)}
    end
  end

  defp cache(conn, body) do
    Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
  end
end
