defmodule Ganesha.Line.Labels do
  @moduledoc """
  Every card, button and outcome label the LINE assistant shows, per locale
  (spec §6.2, §6.3, §6.5). Ledger data is never translated; only these are.
  """

  @labels %{
    confirm: {"確認", "Confirm"},
    discard: {"捨棄", "Discard"},
    enroll_from_request: {"幫他報名", "Sign them up"},
    more_drafts:
      {"還有 %{count} 筆草稿沒有顯示，傳「待確認草稿」可以看全部。",
       "%{count} more drafts are not shown; send “待確認草稿” to see them all."},
    choose: {"請選擇：", "Please choose:"},
    draft: {"草稿", "Draft"},
    pending: {"待確認", "pending"},
    options: {"選項", "Options"},
    confirmed: {"好，已記錄：%{title}", "Done: %{title}"},
    discarded: {"已捨棄：%{title}", "Discarded: %{title}"},
    failed: {"沒辦法套用：%{title}（%{reason}）", "Couldn't apply: %{title} (%{reason})"},
    reason_changed: {"資料已經變了，請再跟我說一次", "the data changed since; please ask me again"},
    reason_not_found: {"找不到相關資料了", "the record is gone"},
    reason_other: {"系統沒辦法完成這筆", "the system couldn't complete it"},
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
    welcome: {"好的！有什麼需要我幫忙的？", "Thanks! How can I help you today?"},
    group_drafts_push_intro:
      {"群組有新草稿待確認，請在下方卡片確認或捨棄。",
       "New drafts from the group chat are waiting below — confirm or discard each card."},
    student_drafts_push_intro:
      {"私訊有人想報名：", "Someone asked to sign up in a private chat:"},
    pending_drafts_section: {"待確認草稿", "Pending drafts"},
    pending_drafts_empty: {"目前沒有待確認的草稿。", "No drafts are waiting."},
    pending_drafts_student_link: {"學生", "Student"}
  }

  @spec t(atom(), String.t() | nil, keyword()) :: String.t()
  def t(key, locale, bindings \\ []) do
    {zh, en} = Map.fetch!(@labels, key)
    template = if locale == "en", do: en, else: zh

    Enum.reduce(bindings, template, fn {name, value}, text ->
      String.replace(text, "%{#{name}}", to_string(value))
    end)
  end

  @changed ~w(purchase_changed attendance_changed package_changed payment_not_claimed
              credit_already_consumed session_cancelled)

  @doc """
  A Draft's stored `failure_reason` as she should read it (chat-first replies
  spec §2). Stored reasons are atom names or a changeset's `field: message`
  text (`Assistant.failure_reason/1`); the latter is already readable.
  """
  @spec failure_reason(term(), String.t() | nil) :: String.t()
  def failure_reason(reason, locale) when is_atom(reason) and not is_nil(reason),
    do: failure_reason(Atom.to_string(reason), locale)

  def failure_reason(reason, locale) when reason in @changed, do: t(:reason_changed, locale)
  def failure_reason("not_found", locale), do: t(:reason_not_found, locale)

  def failure_reason(reason, locale) when is_binary(reason) do
    if String.contains?(reason, ": "), do: reason, else: t(:reason_other, locale)
  end

  def failure_reason(_reason, locale), do: t(:reason_other, locale)
end
