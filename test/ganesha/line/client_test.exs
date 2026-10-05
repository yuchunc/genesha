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

  test "validate_reply/1 asks LINE to check the messages without sending them" do
    parent = self()
    messages = [Client.text_message("嗨")]

    Req.Test.stub(Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, Jason.decode!(body)})
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})
    end)

    assert :ok = Client.validate_reply(messages)

    assert_receive {:request, "POST", "/v2/bot/message/validate/reply",
                    %{"messages" => [%{"type" => "text", "text" => "嗨"}]} = body}

    refute Map.has_key?(body, "replyToken")
  end

  test "validate_reply/1 returns LINE's reason for an invalid message" do
    reason = %{"message" => "A message (messages[0]) in the request body is invalid"}

    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(reason)
    end)

    assert {:error, {400, ^reason}} = Client.validate_reply([%{type: "text", text: ""}])
  end

  test "flex_message/2 wraps the contents and cuts altText to 400 characters" do
    message = Client.flex_message(String.duplicate("字", 450), %{type: "bubble"})

    assert %{type: "flex", contents: %{type: "bubble"}} = message
    assert String.length(message.altText) == 400
  end

  @tag :capture_log
  test "push/2 and loading/2 refuse group and room targets without calling LINE" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      send(parent, {:called, conn.request_path})
      Req.Test.json(conn, %{})
    end)

    for to <- ["Cgroup", "Rroom"] do
      assert {:error, :group_target_forbidden} = Client.push(to, [Client.text_message("嗨")])
      assert {:error, :group_target_forbidden} = Client.loading(to, 20)
    end

    refute_received {:called, _}
  end

  test "get_group_summary/1 fetches the group's name" do
    parent = self()

    Req.Test.stub(Client, fn conn ->
      send(parent, {:request, conn.method, conn.request_path})
      Req.Test.json(conn, %{"groupId" => "Cabc", "groupName" => "瑜伽週三班"})
    end)

    assert {:ok, %{"groupName" => "瑜伽週三班"}} = Client.get_group_summary("Cabc")
    assert_receive {:request, "GET", "/v2/bot/group/Cabc/summary"}
  end
end
