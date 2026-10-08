defmodule Ganesha.Line.VerifySignaturePlugTest do
  # Not async: one test swaps the global :line config.
  use ExUnit.Case, async: false
  @moduletag :capture_log

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

  test "rejects everything when the channel secret is blank, even a body signed with the blank key" do
    line_config = Application.fetch_env!(:ganesha, :line)
    on_exit(fn -> Application.put_env(:ganesha, :line, line_config) end)
    Application.put_env(:ganesha, :line, Keyword.put(line_config, :channel_secret, ""))

    conn = signed_conn(~s({"events":[]}), "")

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        VerifySignaturePlug.call(conn, VerifySignaturePlug.init([]))
      end)

    assert result.halted
    assert result.status == 403
    assert log =~ "LINE_CHANNEL_SECRET"
  end
end
