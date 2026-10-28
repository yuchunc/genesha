defmodule Ganesha.Line.CardsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.{Cards, Labels}

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
      bubble = Cards.draft_bubble(payment(41), "zh-TW")

      assert [%{text: text}] = bubble.body.contents
      assert text == Assistant.draft_summary(payment(41), "zh-TW")
      refute Map.has_key?(bubble, :header)

      assert Enum.map(bubble.footer.contents, &{&1.action.label, &1.action.data}) == [
               {Labels.t(:confirm, "zh-TW"), "action=confirm&draft_id=41"},
               {Labels.t(:discard, "zh-TW"), "action=discard&draft_id=41"}
             ]
    end

    test "a sign-up request card leads with 幫他報名, then 已處理 and 捨棄" do
      draft = %Draft{
        id: 42,
        kind: "signup_request",
        state: "pending",
        parsed: %{"note" => "想報名", "new" => true, "line_user_id" => "Unewcomer"}
      }

      bubble = Cards.draft_bubble(draft, "zh-TW")

      assert Enum.map(bubble.footer.contents, &{&1.action.label, &1.action.data}) == [
               {"幫他報名", "action=enroll_from_request&draft_id=42"},
               {"已處理", "action=confirm&draft_id=42"},
               {"捨棄", "action=discard&draft_id=42"}
             ]
    end

    test "a makeup request card leads with 幫他補課, then 已處理 and 捨棄" do
      draft = %Draft{
        id: 43,
        kind: "makeup_request",
        state: "pending",
        parsed: %{"note" => "8/17"}
      }

      assert Enum.map(Cards.draft_bubble(draft, "en").footer.contents, & &1.action.label) ==
               ["Book makeup", "Handled", "Discard"]

      assert Enum.map(Cards.draft_bubble(draft, "zh-TW").footer.contents, & &1.action.data) == [
               "action=book_from_request&draft_id=43",
               "action=confirm&draft_id=43",
               "action=discard&draft_id=43"
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

  describe "member_notice/2" do
    test "every member notice button's postback data fits LINE's 300 characters" do
      uid = "U" <> String.duplicate("a", 32)

      for name <- [
            String.duplicate("瑜", 20),
            String.duplicate("🧘", 20),
            String.duplicate("👨‍👩‍👧‍👦", 20)
          ],
          args <- [
            %{
              "kind" => "unsure",
              "candidates" => [%{"id" => 1_234_567, "name" => name}],
              "more" => 0
            },
            %{"kind" => "created", "student_id" => 1_234_567, "student_name" => name},
            %{"kind" => "linked", "student_id" => 1_234_567, "student_name" => name}
          ],
          args = Map.merge(args, %{"line_user_id" => uid, "display_name" => name}),
          %{action: %{data: data}} <- footer_buttons(Cards.member_notice(args, "zh-TW")) do
        assert String.length(data) <= 300, "#{byte_size(data)} chars: #{data}"
        assert String.starts_with?(name, URI.decode_query(data)["name"])
      end
    end

    test "member_postback/3 drops whole graphemes until the data fits" do
      args = %{
        "line_user_id" => "U" <> String.duplicate("a", 32),
        "display_name" => String.duplicate("👨‍👩‍👧‍👦", 20)
      }

      data = Cards.member_postback("member_not_student", args, from: "created", sid: 1_234_567)
      name = URI.decode_query(data)["name"]

      assert String.length(data) <= 300
      assert name == String.duplicate("👨‍👩‍👧‍👦", String.length(name))
      assert String.length(name) >= 1
    end

    test "unsure card lists candidates, then new student, then not a student" do
      args = %{
        "kind" => "unsure",
        "line_user_id" => "U1",
        "display_name" => "Amy",
        "candidates" => [%{"id" => 1, "name" => "Amy"}, %{"id" => 2, "name" => "amy"}],
        "more" => 0
      }

      bubble = Cards.member_notice(args, "zh-TW")

      assert Enum.map(
               footer_buttons(bubble),
               &{&1.action.label, URI.decode_query(&1.action.data)}
             ) ==
               [
                 {"Amy",
                  %{"action" => "member_pick", "uid" => "U1", "name" => "Amy", "sid" => "1"}},
                 {"amy",
                  %{"action" => "member_pick", "uid" => "U1", "name" => "Amy", "sid" => "2"}},
                 {"新學生", %{"action" => "member_new", "uid" => "U1", "name" => "Amy"}},
                 {"不是學生",
                  %{
                    "action" => "member_not_student",
                    "uid" => "U1",
                    "name" => "Amy",
                    "from" => "unsure"
                  }}
               ]

      assert bubble.footer.layout == "vertical"
      assert [%{text: "LINE Amy 是哪位學生？"}] = bubble.body.contents

      assert [_, %{text: "還有 2 位同名，請到網頁處理"}] =
               Cards.member_notice(%{args | "more" => 2}, "zh-TW").body.contents
    end

    test "created and linked cards lead with 是學生, then their undo buttons" do
      created = %{
        "kind" => "created",
        "line_user_id" => "U1",
        "display_name" => "小美",
        "student_id" => 7,
        "student_name" => "小美"
      }

      bubble = Cards.member_notice(created, "en")
      assert [%{text: "Added student 小美 (LINE: 小美)"}] = bubble.body.contents
      assert [%{style: "primary"}, %{style: "secondary"}] = footer_buttons(bubble)

      assert Enum.map(
               footer_buttons(bubble),
               &{&1.action.label, URI.decode_query(&1.action.data)}
             ) ==
               [
                 {"Is a student",
                  %{"action" => "member_ok", "uid" => "U1", "name" => "小美", "sid" => "7"}},
                 {"Not a student",
                  %{
                    "action" => "member_not_student",
                    "uid" => "U1",
                    "name" => "小美",
                    "from" => "created",
                    "sid" => "7"
                  }}
               ]

      linked = %{created | "kind" => "linked", "display_name" => "美"}
      bubble = Cards.member_notice(linked, "zh-TW")
      assert [%{text: "已把 LINE 美 連到學生 小美"}] = bubble.body.contents
      assert bubble.footer.layout == "vertical"

      assert Enum.map(
               footer_buttons(bubble),
               &{&1.action.label, URI.decode_query(&1.action.data)}
             ) ==
               [
                 {"是學生", %{"action" => "member_ok", "uid" => "U1", "name" => "美", "sid" => "7"}},
                 {"不是學生",
                  %{
                    "action" => "member_not_student",
                    "uid" => "U1",
                    "name" => "美",
                    "from" => "linked",
                    "sid" => "7"
                  }},
                 {"連錯了",
                  %{"action" => "member_wrong_link", "uid" => "U1", "name" => "美", "sid" => "7"}}
               ]
    end

    test "a long candidate name still fits LINE's 40-character button label" do
      name = String.duplicate("瑜", 50)

      args = %{
        "kind" => "unsure",
        "line_user_id" => "U1",
        "display_name" => "Amy",
        "candidates" => [%{"id" => 1, "name" => name}],
        "more" => 0
      }

      labels = Enum.map(footer_buttons(Cards.member_notice(args, "zh-TW")), & &1.action.label)

      assert Enum.all?(labels, &(String.length(&1) <= 40))
      assert hd(labels) == String.duplicate("瑜", 39) <> "…"
    end

    test "member_postback/3 truncates the LINE name to 20 graphemes" do
      data =
        Cards.member_postback("member_new", %{
          "line_user_id" => "U1",
          "display_name" => String.duplicate("瑜", 25)
        })

      assert URI.decode_query(data) == %{
               "action" => "member_new",
               "uid" => "U1",
               "name" => String.duplicate("瑜", 20)
             }
    end
  end

  defp footer_buttons(bubble), do: bubble.footer.contents
end
