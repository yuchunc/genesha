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
    welcome: {"好的！有什麼需要我幫忙的？", "Thanks! How can I help you today?"},
    # Lookup cards (slice 2)
    card_session: {"課堂", "Session"},
    card_month: {"課表", "Schedule"},
    card_money: {"收支", "Money"},
    card_student: {"學生", "Student"},
    card_credits: {"補課券", "Credits"},
    more_rows: {"…還有 %{count} 筆", "… and %{count} more"},
    cancelled: {"已取消", "Cancelled"},
    roster_count: {"名單 %{count} 人", "Roster: %{count}"},
    no_one_booked: {"還沒有人報名", "No one booked yet"},
    no_show: {"缺席", "No-show"},
    kind_enrolled: {"月課程", "Monthly"},
    kind_makeup: {"補課", "Makeup"},
    kind_drop_in: {"單堂", "Drop-in"},
    kind_trial: {"體驗", "Trial"},
    schedule_title: {"%{month} 課表", "%{month} schedule"},
    sessions_count: {"共 %{count} 堂", "%{count} sessions"},
    booked_count: {"%{count} 人", "%{count} booked"},
    no_sessions: {"這個月還沒有課堂", "No sessions this month"},
    money_title: {"%{month} 收支", "%{month} money"},
    revenue: {"本月收入", "Revenue"},
    tax_threshold: {"營業稅起徵點", "Tax threshold"},
    tax_warn: {"已接近起徵點", "Close to the tax threshold"},
    owed_total: {"未收款 %{amount}", "Owed: %{amount}"},
    nothing_owed: {"沒有人欠款", "Nobody owes anything"},
    owes: {"尚欠 %{amount}", "Owes %{amount}"},
    paid_up: {"已付清", "Paid up"},
    purchases: {"購買紀錄", "Purchases"},
    paid_of: {"已付 %{paid} / %{payable}", "Paid %{paid} of %{payable}"},
    upcoming: {"接下來的課", "Coming up"},
    credits_heading: {"補課券 %{count} 張", "Credits: %{count}"},
    source_package: {"方案補課券", "Package credit"},
    source_cancellation: {"停課補課券", "Cancelled-class credit"},
    expires_on: {"%{date} 到期", "Expires %{date}"},
    no_expiry: {"不會過期", "No expiry"},
    credits_title: {"未使用的補課券", "Open credits"},
    credits_count:
      {"共 %{count} 張，%{expiring} 張本月到期", "%{count} open, %{expiring} expire this month"},
    no_credits: {"沒有未使用的補課券", "No open credits"}
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
