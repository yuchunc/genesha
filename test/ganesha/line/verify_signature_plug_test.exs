defmodule Ganesha.Line.VerifySignaturePlugTest do
  use ExUnit.Case, async: true

  alias Ganesha.Line.VerifySignaturePlug

  defp signed_conn(body, secret \\ "test_channel_secret") do
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

    Plug.Test.conn(:post, "/line/webhook", body)
    |> Plug.Conn.assign(:raw_body, body)
    |> Plug.Conn.put_req_header("x-line-signature", signature)
  end

  test "accepts a body whose signature matches the configured channel secret" do
    conn = signed_conn(~s({"events":[]}))
    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    refute result.halted
  end

  test "rejects a mutated body with 403 and an empty response" do
    conn =
      ~s({"events":[]})
      |> signed_conn()
      |> Plug.Conn.assign(:raw_body, ~s({"events":[{"tampered":true}]}))

    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    assert result.halted
    assert result.status == 403
    assert result.resp_body == ""
  end

  test "rejects a missing signature header" do
    conn = Plug.Test.conn(:post, "/line/webhook", "{}") |> Plug.Conn.assign(:raw_body, "{}")
    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    assert result.halted
    assert result.status == 403
  end

  test "rejects a signature computed with the wrong secret" do
    conn = signed_conn(~s({"events":[]}), "wrong_secret")
    result = VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
    assert result.halted
    assert result.status == 403
  end
end
