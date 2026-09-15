defmodule Ganesha.Line.VerifySignaturePlug do
  @moduledoc """
  Scoped to `/line/webhook` only, never application-wide. Verifies
  `x-line-signature` against `Base64(HMAC-SHA256(channel_secret, raw_body))`
  using the bytes `Ganesha.Line.RawBodyPlug` cached before `Plug.Parsers`
  consumed the body (spec §2, original design §5.1).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    channel_secret = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_secret)
    raw_body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("x-line-signature") |> List.first()

    if valid_signature?(channel_secret, raw_body, signature) do
      conn
    else
      conn |> send_resp(403, "") |> halt()
    end
  end

  defp valid_signature?(_secret, _body, nil), do: false

  defp valid_signature?(secret, body, signature) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, signature)
  end
end
