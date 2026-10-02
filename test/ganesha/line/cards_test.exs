defmodule Ganesha.Line.CardsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Cards

  defp payment(id) do
    %Draft{
      id: id,
      kind: "record_payment",
      state: "pending",
      parsed: %{
        "student_id" => 7,
        "student_name" => "Lulu",
        "purchase_id" => 3,
        "amount" => 1600,
        "method" => "line_pay",
        "paid_on" => "2026-10-02",
        "package_name" => "月課程",
        "before_owed" => 1600
      }
    }
  end

  test "a Draft card shows its title, lines and before → after, with Confirm, Discard and the web page" do
    bubble = Cards.render({:draft, payment(41)}, "zh-TW")

    assert %{type: "bubble", header: %{contents: [%{type: "text", text: "收款 Lulu NT$1,600"}]}} =
             bubble

    texts = Enum.map(bubble.body.contents, & &1.text)
    assert "方案：月課程" in texts
    assert "尚欠: NT$1,600 → NT$0" in texts

    assert [confirm, discard, web] = bubble.footer.contents
    assert confirm.action == %{type: "postback", label: "確認", data: "action=confirm&draft_id=41"}
    assert discard.action == %{type: "postback", label: "捨棄", data: "action=discard&draft_id=41"}
    assert web.action.type == "uri"
    assert String.ends_with?(web.action.uri, "/students/7")
  end

  test "a change with no before value shows only the after value" do
    draft = %Draft{
      id: 6,
      kind: "book_one_off",
      parsed: %{
        "session_id" => 9,
        "student_name" => "Lulu",
        "package_name" => "單堂",
        "package_kind" => "drop_in",
        "price" => 400,
        "session_date" => "2026-10-07",
        "session_label" => "基礎",
        "session_time" => "19:00–20:15",
        "before_count" => 3
      }
    }

    texts = Enum.map(Cards.render({:draft, draft}, "zh-TW").body.contents, & &1.text)
    assert "名單: 3 人 → 4 人" in texts
    assert "應付: NT$400" in texts
  end

  test "no web button without a web path, and labels follow the chat's language" do
    draft = %Draft{id: 5, kind: "makeup_request", parsed: %{"note" => "想補 8/17"}}
    bubble = Cards.render({:draft, draft}, "en")

    assert [%{action: %{label: "Confirm"}}, %{action: %{label: "Discard"}}] =
             bubble.footer.contents

    assert [%{text: "想補 8/17"}] = bubble.body.contents
  end

  test "history_line/2 names the Draft for the model" do
    assert Cards.history_line({:draft, payment(41)}, "zh-TW") == "[草稿 #41 待確認] 收款 Lulu NT$1,600"

    assert Cards.history_line({:draft, payment(41)}, "en") ==
             "[Draft #41 pending] Payment Lulu NT$1,600"
  end

  test "a Draft carousel holds at most 12 bubbles" do
    carousel = Cards.draft_carousel(Enum.map(1..13, &payment/1), "zh-TW")

    assert %{type: "carousel", contents: bubbles} = carousel
    assert length(bubbles) == 12
  end
end
