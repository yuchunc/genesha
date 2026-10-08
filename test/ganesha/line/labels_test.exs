defmodule Ganesha.Line.LabelsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Line.Labels

  @keys ~w(confirm discard handled more_drafts choose draft pending options confirmed discarded
           failed reason_changed reason_not_found reason_other reason_request_already_handled
           reason_line_user_id_taken already_handled replaced
           not_found exception tag_confirmed tag_discarded
           tag_failed tag_already_handled tag_replaced tag_exception apology unknown_action
           text_only welcome group_drafts_push_intro student_drafts_push_intro
           enroll_from_request book_from_request
           pending_drafts_section pending_drafts_empty pending_drafts_student_link)a

  test "every label speaks both languages, and they differ" do
    for key <- @keys do
      zh = Labels.t(key, "zh-TW")
      en = Labels.t(key, "en")

      assert is_binary(zh) and zh != "", "#{key} has no zh-TW label"
      assert is_binary(en) and en != "", "#{key} has no en label"
      assert zh != en, "#{key} is not translated"
    end
  end

  test "any locale other than en gets Traditional Chinese" do
    for key <- @keys, locale <- [nil, "ja", "zh-TW"] do
      assert Labels.t(key, locale) == Labels.t(key, "zh-TW")
    end
  end

  test "fills in an outcome's details" do
    for locale <- ["zh-TW", "en"] do
      text = Labels.t(:failed, locale, title: "收款 Amy NT$3,200", reason: "missing_purchase_id")

      assert text =~ "收款 Amy NT$3,200"
      assert text =~ "missing_purchase_id"
      refute text =~ "%{"
    end

    assert Labels.t(:more_drafts, "en", count: 3) =~ "3"
  end

  test "stored failure reasons read as a sentence, never as an error code" do
    for reason <- ~w(purchase_changed attendance_changed package_changed payment_not_claimed
                     credit_already_consumed session_cancelled student_line_user_id_changed
                     request_already_handled line_user_id_taken not_found boom),
        locale <- ["zh-TW", "en"] do
      refute Labels.failure_reason(reason, locale) =~ "_"
    end

    assert Labels.failure_reason("purchase_changed", "zh-TW") ==
             Labels.failure_reason("attendance_changed", "zh-TW")

    assert Labels.failure_reason("amount: must be greater than 0", "zh-TW") ==
             "amount: must be greater than 0"

    assert Labels.failure_reason(:request_already_handled, "zh-TW") == "這個申請已經處理過了"

    assert Labels.failure_reason("request_already_handled", "en") ==
             "This request was already handled"
  end

  test "the text-only reply and the request buttons read as the spec says" do
    assert Labels.t(:text_only, "zh-TW") == "我目前只看得懂文字訊息，請用文字告訴我。"

    assert Labels.t(:text_only, "en") ==
             "I can only read text messages for now; please type it out."

    assert Labels.t(:handled, "zh-TW") == "已處理"
    assert Labels.t(:book_from_request, "zh-TW") == "幫他補課"
  end
end
