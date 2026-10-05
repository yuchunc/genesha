defmodule Ganesha.Line.Client do
  @moduledoc """
  Req-based LINE Messaging API client (spec §2, §5). Reply is free and is
  always tried first; push costs quota and is only the fallback for an
  expired reply token (original design §7.1) — negligible at the teacher's
  1:1 volume.
  """
  @behaviour Ganesha.Line.ClientBehaviour

  require Logger

  @base_url "https://api.line.me"

  @impl true
  def reply(reply_token, messages) when is_list(messages) do
    post("/v2/bot/message/reply", %{replyToken: reply_token, messages: messages})
  end

  @impl true
  def push(to, messages) when is_list(messages) do
    with :ok <- refuse_group_target(to) do
      post("/v2/bot/message/push", %{to: to, messages: messages})
    end
  end

  @doc "Shows LINE's loading animation in a 1:1 chat while the assistant thinks (spec §6.1)."
  @impl true
  def loading(chat_id, seconds) when is_integer(seconds) and seconds > 0 do
    with :ok <- refuse_group_target(chat_id) do
      post("/v2/bot/chat/loading/start", %{chatId: chat_id, loadingSeconds: seconds})
    end
  end

  @doc """
  Asks LINE whether `messages` would be accepted as a reply, without sending
  anything to anyone (spec §8, `mix line.validate_cards`).
  """
  @impl true
  def validate_reply(messages) when is_list(messages) do
    post("/v2/bot/message/validate/reply", %{messages: messages})
  end

  @impl true
  def get_group_member(group_id, user_id) do
    case Req.get(req(), url: "/v2/bot/group/#{group_id}/member/#{user_id}") do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Spec 2026-10-05 §4: the bot never posts into a group (C…) or a room (R…),
  # whichever caller asks.
  defp refuse_group_target("C" <> _ = to), do: forbid(to)
  defp refuse_group_target("R" <> _ = to), do: forbid(to)
  defp refuse_group_target(_to), do: :ok

  defp forbid(to) do
    Logger.error("LINE send to #{to} refused: the bot never posts in groups or rooms")
    {:error, :group_target_forbidden}
  end

  defp post(path, body) do
    case Req.post(req(), url: path, json: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp req do
    token = Application.fetch_env!(:ganesha, :line) |> Keyword.fetch!(:channel_access_token)
    options = :ganesha |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])

    Req.new([base_url: @base_url, headers: [{"authorization", "Bearer #{token}"}]] ++ options)
  end

  @doc "A plain text message. Drafts are confirmed from their Flex card (`Ganesha.Line.Cards`)."
  def text_message(text), do: %{type: "text", text: text}

  @doc "A Flex message holding one bubble or carousel; LINE caps `altText` at 400 characters."
  def flex_message(alt_text, contents) when is_binary(alt_text) and is_map(contents) do
    %{type: "flex", altText: String.slice(alt_text, 0, 400), contents: contents}
  end

  defp quick_reply_item(label, data),
    do: %{type: "action", action: %{type: "postback", label: label, data: data}}

  @doc "First-contact language picker for 1:1 chats."
  def language_picker_message do
    %{
      type: "text",
      text: "請選擇語言 / Please choose your language:",
      quickReply: %{
        items: [
          quick_reply_item("繁體中文", "action=set_locale&locale=zh-TW"),
          quick_reply_item("English", "action=set_locale&locale=en")
        ]
      }
    }
  end
end
