defmodule GaneshaWeb.LineWebhookControllerTest do
  use GaneshaWeb.ConnCase, async: true

  alias Ganesha.{Line, Repo}

  defp signed_post(conn, body) do
    secret = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_secret)
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-line-signature", signature)
    |> post("/line/webhook", body)
  end

  test "answers 200 for the empty connectivity probe", %{conn: conn} do
    conn = signed_post(conn, ~s({"events":[]}))
    assert conn.status == 200
  end

  test "persists a real event and answers 200", %{conn: conn} do
    # `mode: "standby"` — `Ganesha.Assistant.ProcessEventWorker` (Task 15)
    # does not exist yet, and `Line.record_event/1` only enqueues it for
    # active-mode events.
    body =
      Jason.encode!(%{
        "events" => [
          %{
            "webhookEventId" => "evt-1",
            "type" => "message",
            "mode" => "standby",
            "source" => %{"type" => "user", "userId" => "U1"},
            "replyToken" => "rt-1",
            "message" => %{"type" => "text", "text" => "hi"}
          }
        ]
      })

    conn = signed_post(conn, body)
    assert conn.status == 200
    assert Repo.get_by(Line.LineEvent, webhook_event_id: "evt-1")
  end

  test "rejects an unsigned request with 403", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> post("/line/webhook", "{}")

    assert conn.status == 403
  end
end
