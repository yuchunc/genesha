defmodule Ganesha.Line.VerifySignaturePlug do
  @moduledoc """
  Scoped to `/line/webhook` only, never application-wide. Verifies
  `x-line-signature` against `Base64(HMAC-SHA256(channel_secret, raw_body))`
  using the bytes `Ganesha.Line.RawBodyPlug` cached before `Plug.Parsers`
  consumed the body (spec §2, original design §5.1).

  A blank channel secret is a misconfiguration (e.g. the dev server booted
  without `.env.dev`, which `mise.toml` loads): every request is rejected, and logged, rather
  than accepting bodies signed with the empty key.
  """
  import Plug.Conn

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    channel_secret = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_secret)
    raw_body = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("x-line-signature") |> List.first()

    cond do
      channel_secret in [nil, ""] ->
        Logger.error("LINE webhook rejected: LINE_CHANNEL_SECRET is not configured")
        reject(conn)

      valid_signature?(channel_secret, raw_body, signature) ->
        conn

      true ->
        Logger.warning(
          "LINE webhook rejected: x-line-signature does not match LINE_CHANNEL_SECRET"
        )

        reject(conn)
    end
  end

  defp reject(conn), do: conn |> send_resp(403, "") |> halt()

  defp valid_signature?(_secret, _body, nil), do: false

  defp valid_signature?(secret, body, signature) do
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()
    Plug.Crypto.secure_compare(expected, signature)
  end
end
