defmodule Ganesha.Line.CardsTest do
  use ExUnit.Case, async: true

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

  defp texts(bubble), do: Enum.map(bubble.body.contents, & &1.text)
  defp header_text(bubble), do: hd(bubble.header.contents).text

  defp session_payload(attendees) do
    %{
      "title" => "10/7 週三 基礎 19:00–20:15",
      "style" => "Hatha",
      "count" => length(attendees),
      "cancelled" => false,
      "attendees" => attendees
    }
  end

  defp credit(student, expires),
    do: %{"student" => student, "source" => "package", "expires" => expires}

  describe "lookup cards" do
    test "a session card puts the session in the header and lists each attendee with their kind" do
      payload =
        session_payload([
          %{"name" => "Lulu", "kind" => "enrolled", "no_show" => false},
          %{"name" => "Amy", "kind" => "drop_in", "no_show" => true}
        ])

      bubble = Cards.render({:session, payload}, "en")

      assert header_text(bubble) == payload["title"]
      lines = texts(bubble)
      assert "Hatha" in lines
      assert Labels.t(:roster_count, "en", count: 2) in lines

      assert [lulu] = Enum.filter(lines, &String.starts_with?(&1, "Lulu"))
      assert lulu =~ Labels.t(:kind_enrolled, "en")
      refute lulu =~ Labels.t(:no_show, "en")

      assert [amy] = Enum.filter(lines, &String.starts_with?(&1, "Amy"))
      assert amy =~ Labels.t(:kind_drop_in, "en")
      assert amy =~ Labels.t(:no_show, "en")
    end

    test "a cancelled session says so" do
      payload = Map.put(session_payload([]), "cancelled", true)
      assert Labels.t(:cancelled, "zh-TW") in texts(Cards.render({:session, payload}, "zh-TW"))

      refute Labels.t(:cancelled, "zh-TW") in texts(
               Cards.render({:session, session_payload([])}, "zh-TW")
             )
    end

    test "a month card shows the month, the session count and one row per session" do
      payload = %{
        "month" => "2026年10月",
        "session_count" => 2,
        "rows" => [
          %{"day" => "10/7 週三", "label" => "基礎", "time" => "19:00", "count" => 2},
          %{"day" => "10/14 週三", "label" => "流動", "time" => "18:00", "count" => 0}
        ]
      }

      bubble = Cards.render({:month, payload}, "zh-TW")

      assert header_text(bubble) =~ "2026年10月"
      assert [count_line, first, second] = texts(bubble)
      assert count_line == Labels.t(:sessions_count, "zh-TW", count: 2)
      assert first =~ "10/7 週三" and first =~ "基礎" and first =~ "19:00"
      assert first =~ Labels.t(:booked_count, "zh-TW", count: 2)
      assert second =~ "10/14 週三" and second =~ "流動" and second =~ "18:00"
      assert second =~ Labels.t(:booked_count, "zh-TW", count: 0)
    end

    test "a month card shows at most 10 sessions and a row naming how many more there are" do
      rows =
        for n <- 1..12,
            do: %{"day" => "10/#{n}", "label" => "基礎", "time" => "19:00", "count" => 1}

      bubble =
        Cards.render(
          {:month, %{"month" => "2026年10月", "session_count" => 12, "rows" => rows}},
          "zh-TW"
        )

      [_count | lines] = texts(bubble)
      assert length(lines) == 11
      assert Enum.all?(Enum.take(lines, 10), &String.starts_with?(&1, "10/"))
      refute Enum.any?(lines, &String.starts_with?(&1, "10/11 "))
      assert List.last(lines) == Labels.t(:more_rows, "zh-TW", count: 2)
    end

    test "a money card shows revenue, the tax warning and who owes what" do
      payload = %{
        "month" => "October 2026",
        "revenue" => "NT$48,000",
        "tax_warn" => true,
        "owed_total" => "NT$4,800",
        "debtors" => [
          %{"name" => "Amy", "amount" => "NT$3,200"},
          %{"name" => "Lulu", "amount" => "NT$1,600"}
        ]
      }

      bubble = Cards.render({:money, payload}, "en")
      lines = texts(bubble)

      assert header_text(bubble) =~ "October 2026"
      assert Enum.any?(lines, &(&1 =~ "NT$48,000"))
      assert Enum.any?(lines, &(&1 =~ Labels.t(:tax_warn, "en")))
      assert Labels.t(:owed_total, "en", amount: "NT$4,800") in lines
      assert Enum.any?(lines, &(&1 =~ "Amy" and &1 =~ "NT$3,200"))
      assert Enum.any?(lines, &(&1 =~ "Lulu" and &1 =~ "NT$1,600"))

      quiet = Cards.render({:money, Map.put(payload, "tax_warn", false)}, "en")
      refute Enum.any?(texts(quiet), &(&1 =~ Labels.t(:tax_warn, "en")))
    end

    test "a money card shows at most 10 debtors and a row naming how many more there are" do
      debtors = for n <- 1..13, do: %{"name" => "S#{n}", "amount" => "NT$100"}

      payload = %{
        "month" => "2026年10月",
        "revenue" => "NT$0",
        "tax_warn" => false,
        "owed_total" => "NT$1,300",
        "debtors" => debtors
      }

      lines = texts(Cards.render({:money, payload}, "zh-TW"))

      assert Enum.count(lines, &String.starts_with?(&1, "S")) == 10
      refute Enum.any?(lines, &String.starts_with?(&1, "S11:"))
      assert List.last(lines) == Labels.t(:more_rows, "zh-TW", count: 3)
    end

    test "a student card shows what they owe, their purchases, upcoming sessions and credits" do
      payload = %{
        "name" => "Lulu",
        "owed" => "NT$1,600",
        "purchases" => [%{"package" => "月課程", "paid" => "NT$1,600", "payable" => "NT$3,200"}],
        "upcoming" => [%{"day" => "10/7 週三", "label" => "基礎"}],
        "credits" => 2
      }

      bubble = Cards.render({:student, payload}, "zh-TW")
      lines = texts(bubble)

      assert header_text(bubble) =~ "Lulu"
      assert Labels.t(:owes, "zh-TW", amount: "NT$1,600") in lines
      assert Enum.any?(lines, &(&1 =~ "月課程" and &1 =~ "NT$1,600" and &1 =~ "NT$3,200"))
      assert Enum.any?(lines, &(&1 =~ "10/7 週三" and &1 =~ "基礎"))
      assert Labels.t(:credits_heading, "zh-TW", count: 2) in lines

      paid_up = Cards.render({:student, Map.put(payload, "owed", "NT$0")}, "zh-TW")
      assert Labels.t(:paid_up, "zh-TW") in texts(paid_up)
    end

    test "a credits card summarises the count and lists each credit's student, source and expiry" do
      payload = %{
        "count" => 2,
        "expiring_count" => 1,
        "rows" => [
          credit("Lulu", "10/31"),
          %{"student" => "Amy", "source" => "cancellation", "expires" => nil}
        ]
      }

      lines = texts(Cards.render({:credits, payload}, "en"))

      assert hd(lines) == Labels.t(:credits_count, "en", count: 2, expiring: 1)

      assert Enum.any?(lines, fn line ->
               line =~ "Lulu" and line =~ Labels.t(:source_package, "en") and
                 line =~ Labels.t(:expires_on, "en", date: "10/31")
             end)

      assert Enum.any?(lines, fn line ->
               line =~ "Amy" and line =~ Labels.t(:source_cancellation, "en") and
                 line =~ Labels.t(:no_expiry, "en")
             end)
    end

    test "a credits card shows at most 10 credits and a row naming how many more there are" do
      rows = for n <- 1..14, do: credit("S#{n}", nil)
      payload = %{"count" => 14, "expiring_count" => 0, "rows" => rows}

      lines = texts(Cards.render({:credits, payload}, "zh-TW"))

      assert Enum.count(lines, &String.starts_with?(&1, "S")) == 10
      refute Enum.any?(lines, &String.starts_with?(&1, "S11 "))
      assert List.last(lines) == Labels.t(:more_rows, "zh-TW", count: 4)
    end

    test "a session card shows at most 20 attendees and a row naming how many more there are" do
      attendees =
        for n <- 1..25, do: %{"name" => "S#{n}", "kind" => "enrolled", "no_show" => false}

      lines = texts(Cards.render({:session, session_payload(attendees)}, "zh-TW"))

      assert Labels.t(:roster_count, "zh-TW", count: 25) in lines
      assert Enum.count(lines, &String.starts_with?(&1, "S")) == 20
      assert List.last(lines) == Labels.t(:more_rows, "zh-TW", count: 5)
    end

    test "cards with nothing to list say so instead of showing an empty body" do
      empty = %{
        session: {session_payload([]), :no_one_booked},
        month: {%{"month" => "2026年10月", "session_count" => 0, "rows" => []}, :no_sessions},
        money:
          {%{
             "month" => "2026年10月",
             "revenue" => "NT$0",
             "tax_warn" => false,
             "owed_total" => "NT$0",
             "debtors" => []
           }, :nothing_owed},
        credits: {%{"count" => 0, "expiring_count" => 0, "rows" => []}, :no_credits}
      }

      for {type, {payload, label}} <- empty, locale <- ["zh-TW", "en"] do
        assert Labels.t(label, locale) in texts(Cards.render({type, payload}, locale)),
               "#{type} #{locale}"
      end
    end

    test "history_line/2 names the card and what it is about for the model" do
      for locale <- ["zh-TW", "en"] do
        assert Cards.history_line({:session, session_payload([])}, locale) ==
                 "[#{Labels.t(:card_session, locale)}] 10/7 週三 基礎 19:00–20:15"

        assert Cards.history_line({:month, %{"month" => "2026年10月"}}, locale) ==
                 "[#{Labels.t(:card_month, locale)}] 2026年10月"

        assert Cards.history_line({:money, %{"month" => "2026年10月"}}, locale) ==
                 "[#{Labels.t(:card_money, locale)}] 2026年10月"

        assert Cards.history_line({:student, %{"name" => "Lulu"}}, locale) ==
                 "[#{Labels.t(:card_student, locale)}] Lulu"

        assert Cards.history_line({:credits, %{"count" => 3}}, locale) ==
                 "[#{Labels.t(:card_credits, locale)}] 3"
      end
    end
  end

  describe "samples/1" do
    test "has every card type, including lookup cards with nothing to list" do
      samples = Cards.samples("zh-TW")
      types = samples |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert types == Enum.sort([:session, :month, :money, :student, :credits, :draft])

      assert Enum.any?(samples, &match?({:session, %{"attendees" => []}}, &1))
      assert Enum.any?(samples, &match?({:month, %{"rows" => []}}, &1))
      assert Enum.any?(samples, &match?({:money, %{"debtors" => []}}, &1))
      assert Enum.any?(samples, &match?({:student, %{"purchases" => [], "upcoming" => []}}, &1))
      assert Enum.any?(samples, &match?({:credits, %{"rows" => []}}, &1))
    end

    # LINE rejects a Flex message with an empty text or a box with no contents.
    test "no sample card has an empty text or an empty box, in either locale" do
      for locale <- ["zh-TW", "en"], card <- Cards.samples(locale) do
        bubble =
          case card do
            {:draft, draft} -> Cards.draft_carousel([draft], locale)
            card -> Cards.render(card, locale)
          end

        for node <- flex_nodes(bubble) do
          refute match?(%{type: "text", text: text} when text in [nil, ""], node),
                 "empty text in #{locale} #{elem(card, 0)}: #{inspect(node)}"

          refute match?(%{type: "box", contents: []}, node),
                 "empty box in #{locale} #{elem(card, 0)}: #{inspect(node)}"
        end

        assert String.trim(Cards.history_line(card, locale)) != ""
      end
    end
  end

  defp flex_nodes(%{} = node) do
    children =
      node
      |> Map.take([:header, :hero, :body, :footer, :contents])
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&is_map/1)

    [node | Enum.flat_map(children, &flex_nodes/1)]
  end
end
