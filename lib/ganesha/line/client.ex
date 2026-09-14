defmodule Ganesha.Line.Client do
  @moduledoc """
  Req-based LINE Messaging API client (spec §2, §5). Reply is free and is
  always tried first; push costs quota and is only the fallback for an
  expired reply token (original design §7.1) — negligible at the teacher's
  1:1 volume.
  """
  @behaviour Ganesha.Line.ClientBehaviour

  @base_url "https://api.line.me"

  @impl true
  def reply(reply_token, messages) when is_list(messages) do
    post("/v2/bot/message/reply", %{replyToken: reply_token, messages: messages})
  end

  @impl true
  def push(to, messages) when is_list(messages) do
    post("/v2/bot/message/push", %{to: to, messages: messages})
  end

  @impl true
  def get_group_member(group_id, user_id) do
    case Req.get(req(), url: "/v2/bot/group/#{group_id}/member/#{user_id}") do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(path, body) do
    case Req.post(req(), url: path, json: body) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    token = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_access_token)
    Req.new(base_url: @base_url, headers: [{"authorization", "Bearer #{token}"}])
  end

  @doc "A plain text message, or one with a 確認/捨棄 quick reply for `draft_id`."
  def text_message(text, draft_id \\ nil)
  def text_message(text, nil), do: %{type: "text", text: text}

  def text_message(text, draft_id) when is_integer(draft_id) do
    %{
      type: "text",
      text: text,
      quickReply: %{
        items: [
          quick_reply_item("確認", "action=confirm&draft_id=#{draft_id}"),
          quick_reply_item("捨棄", "action=discard&draft_id=#{draft_id}")
        ]
      }
    }
  end

  defp quick_reply_item(label, data), do: %{type: "action", action: %{type: "postback", label: label, data: data}}
end
