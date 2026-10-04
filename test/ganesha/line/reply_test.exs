defmodule Ganesha.Line.ReplyTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.{Draft, Turn}
  alias Ganesha.Line.{Cards, Labels, Reply}

  defp draft(id) do
    %Draft{
      id: id,
      kind: "makeup_request",
      state: "pending",
      parsed: %{"note" => "想補 #{id}", "student_id" => id, "student_name" => "學生#{id}"}
    }
  end

  defp drafts(n), do: Enum.map(1..n, &draft/1)

  defp line(draft), do: Cards.history_line({:draft, draft}, "zh-TW")

  defp lookup(title),
    do: {:session, %{"title" => title, "count" => 0, "cancelled" => false, "attendees" => []}}

  test "text alone is one text message" do
    assert [%{type: "text", text: "好的"}] = Reply.build(%Turn{text: "好的"}, [], "zh-TW")
  end

  test "text first, then one Draft carousel" do
    assert [
             %{type: "text", text: "已建立草稿。"},
             %{type: "flex", altText: alt, contents: %{type: "carousel", contents: [_, _]}}
           ] = Reply.build(%Turn{text: "已建立草稿。", draft_ids: [1, 2]}, drafts(2), "zh-TW")

    assert alt =~ line(draft(1))
  end

  test "more than 12 Drafts: the carousel shows 12 and the text says how many more" do
    assert [text, carousel] = Reply.build(%Turn{text: "好了"}, drafts(14), "zh-TW")
    assert length(carousel.contents.contents) == 12
    assert text.text =~ "好了"
    assert text.text =~ Labels.t(:more_drafts, "zh-TW", count: 2)
  end

  test "never more than 5 messages: lookup cards past the limit are dropped" do
    cards = Enum.map(1..6, &lookup("課堂#{&1}"))
    messages = Reply.build(%Turn{text: "看看", cards: cards}, drafts(1), "zh-TW")

    assert [
             %{type: "text"},
             %{contents: %{type: "bubble"}},
             %{contents: %{type: "bubble"}},
             %{contents: %{type: "bubble"}},
             %{contents: %{type: "carousel"}}
           ] = messages
  end

  test "no Drafts means no carousel message, never an empty one" do
    messages = Reply.build(%Turn{text: "看看", cards: [lookup("課堂")]}, [], "zh-TW")

    assert [%{type: "text"}, %{type: "flex", contents: %{type: "bubble"}}] = messages
    refute Enum.any?(messages, &match?(%{contents: %{type: "carousel"}}, &1))
  end

  test "every Flex message carries an altText of at most 400 characters" do
    long = %Draft{
      id: 1,
      kind: "makeup_request",
      parsed: %{"note" => "x", "student_name" => String.duplicate("長", 500)}
    }

    messages =
      Reply.build(
        %Turn{cards: [lookup(String.duplicate("長", 500))]},
        List.duplicate(long, 3),
        "zh-TW"
      )

    assert length(messages) == 2

    for %{type: "flex"} = message <- messages do
      assert is_binary(message.altText)
      assert message.altText != ""
      assert String.length(message.altText) <= 400
    end
  end

  test "text longer than LINE's 5000-character limit is cut to fit" do
    assert [%{type: "text", text: text}] =
             Reply.build(%Turn{text: String.duplicate("字", 6000)}, [], "zh-TW")

    assert String.length(text) == 5000
  end

  test "choices become quick replies on the last message only" do
    assert [text, carousel] =
             Reply.build(%Turn{text: "哪一位？", choices: ["週二", "週四"]}, drafts(1), "zh-TW")

    refute Map.has_key?(text, :quickReply)

    assert [
             %{type: "action", action: %{type: "message", label: "週二", text: "週二"}},
             %{type: "action", action: %{type: "message", label: "週四", text: "週四"}}
           ] = carousel.quickReply.items
  end

  test "choices with nothing else to say still get a message to ride on" do
    assert [%{type: "text", text: text, quickReply: %{items: [_, _]}}] =
             Reply.build(%Turn{choices: ["A", "B"]}, [], "zh-TW")

    assert text != ""
  end

  test "an empty turn sends nothing" do
    assert Reply.build(%Turn{}, [], "zh-TW") == []
  end

  describe "history_text/3" do
    test "names every Draft and the choices offered" do
      [one, two] = drafts(2)

      assert Reply.history_text(%Turn{choices: ["A", "B"]}, [one, two], "zh-TW") ==
               Enum.join(
                 [line(one), line(two), "[#{Labels.t(:options, "zh-TW")}] A / B"],
                 "\n"
               )
    end

    test "names every Draft even past the twelve the carousel shows" do
      all = drafts(14)
      history = Reply.history_text(%Turn{}, all, "zh-TW")

      assert String.split(history, "\n") == Enum.map(all, &line/1)
    end

    test "names only the lookup cards that were sent" do
      cards = Enum.map(1..6, &lookup("課堂#{&1}"))
      history = Reply.history_text(%Turn{text: "看看", cards: cards}, drafts(1), "zh-TW")

      # text + carousel leave room for three of the six lookup cards
      assert String.split(history, "\n") ==
               Enum.map(1..3, &Cards.history_line(lookup("課堂#{&1}"), "zh-TW")) ++
                 [line(draft(1))]
    end

    test "is nil when the turn sent no cards" do
      assert Reply.history_text(%Turn{text: "hi"}, [], "zh-TW") == nil
    end
  end
end
