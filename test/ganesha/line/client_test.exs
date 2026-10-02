defmodule Ganesha.Line.ClientTest do
  use ExUnit.Case, async: true
  alias Ganesha.Line.Client

  test "text_message/1 builds a plain text message" do
    assert Client.text_message("嗨") == %{type: "text", text: "嗨"}
  end

  test "loading/2 starts LINE's loading animation in the chat" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{})
    end)

    assert :ok = Client.loading("Uteacher", 20)

    assert_receive {:request, "POST", "/v2/bot/chat/loading/start",
                    %{"chatId" => "Uteacher", "loadingSeconds" => 20}}
  end

  test "loading/2 reports LINE's refusal" do
    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"message" => "bad"})
    end)

    assert {:error, {400, %{"message" => "bad"}}} = Client.loading("Uteacher", 20)
  end

  test "flex_message/2 wraps the contents and cuts altText to 400 characters" do
    message = Client.flex_message(String.duplicate("字", 450), %{type: "bubble"})

    assert %{type: "flex", contents: %{type: "bubble"}} = message
    assert String.length(message.altText) == 400
  end
end
