defmodule Ganesha.Line.CardsTest do
  use Ganesha.DataCase, async: true

  alias Ganesha.Assistant
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

  describe "draft_bubble/2" do
    test "the body is the Draft's summary and the footer is exactly Confirm and Discard" do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

      bubble = Cards.draft_bubble(draft, "zh-TW")

      assert [%{text: text}] = bubble.body.contents
      assert text == Assistant.draft_summary(draft, "zh-TW")
      refute Map.has_key?(bubble, :header)

      assert Enum.map(bubble.footer.contents, & &1.action.data) == [
               "action=confirm&draft_id=#{draft.id}",
               "action=discard&draft_id=#{draft.id}"
             ]
    end
  end

  test "history_line/2 names the Draft by id and summary for the model" do
    for locale <- ["zh-TW", "en"] do
      line = Cards.history_line({:draft, payment(41)}, locale)
      assert line =~ "#41"
      assert line =~ Assistant.draft_summary(payment(41), locale)
    end
  end

  test "a Draft carousel holds at most 12 bubbles" do
    carousel = Cards.draft_carousel(Enum.map(1..13, &payment/1), "zh-TW")

    assert %{type: "carousel", contents: bubbles} = carousel
    assert length(bubbles) == 12
  end
end
