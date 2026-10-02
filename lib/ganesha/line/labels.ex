defmodule Ganesha.Line.Labels do
  @moduledoc """
  Every card, button and outcome label the LINE assistant shows, per locale
  (spec §6.2, §6.3, §6.5). Ledger data is never translated; only these are.
  """

  @labels %{
    confirm: {"確認", "Confirm"},
    discard: {"捨棄", "Discard"},
    open_web: {"在網頁開啟", "Open on web"},
    more_drafts:
      {"還有 %{count} 筆草稿沒有顯示，傳「待確認草稿」可以看全部。",
       "%{count} more drafts are not shown; send “待確認草稿” to see them all."},
    choose: {"請選擇：", "Please choose:"},
    draft: {"草稿", "Draft"},
    pending: {"待確認", "pending"},
    options: {"選項", "Options"},
    confirmed: {"已確認：%{title}", "Confirmed: %{title}"},
    discarded: {"已捨棄：%{title}", "Discarded: %{title}"},
    failed: {"無法套用：%{title}（%{reason}）", "Couldn't apply: %{title} (%{reason})"},
    already_handled: {"這筆草稿已經處理過了。", "This draft was already handled."},
    replaced: {"這筆草稿已被取代。", "This draft was replaced."},
    not_found: {"找不到這筆草稿。", "Draft not found."},
    exception: {"記錄失敗，請稍後再試。", "Something went wrong; please try again."},
    tag_confirmed: {"已確認", "Confirmed"},
    tag_discarded: {"已捨棄", "Discarded"},
    tag_failed: {"無法套用", "Couldn't apply"},
    tag_already_handled: {"已處理過", "Already handled"},
    tag_replaced: {"已被取代", "Replaced"},
    tag_exception: {"確認失敗", "Confirm failed"},
    apology:
      {"抱歉，我現在無法處理這則訊息，請稍後再試一次。",
       "Sorry, I couldn't process that message. Please try again later."},
    unknown_action: {"無法辨識的操作。", "Unrecognized action."},
    welcome: {"好的！有什麼需要我幫忙的？", "Thanks! How can I help you today?"}
  }

  @spec t(atom(), String.t() | nil, keyword()) :: String.t()
  def t(key, locale, bindings \\ []) do
    {zh, en} = Map.fetch!(@labels, key)
    template = if locale == "en", do: en, else: zh

    Enum.reduce(bindings, template, fn {name, value}, text ->
      String.replace(text, "%{#{name}}", to_string(value))
    end)
  end
end
