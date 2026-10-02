defmodule Ganesha.Line.Reply do
  @moduledoc """
  Packs a `Ganesha.Assistant.Turn` into at most five LINE messages (spec §6.2):
  the text, then lookup cards (one bubble each), then one Draft carousel.
  Lookup cards that do not fit are dropped; Drafts past twelve are counted in
  the text instead. Choices ride on the last message as quick replies.
  """

  alias Ganesha.Assistant.{Draft, Turn}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_messages 5
  @max_bubbles 12
  @max_text 5000

  @spec build(Turn.t(), [Draft.t()], String.t()) :: [map()]
  def build(%Turn{} = turn, drafts, locale) do
    plan = plan(turn, drafts, locale)

    texts = if plan.text, do: [Client.text_message(plan.text)], else: []

    cards =
      Enum.map(
        plan.cards,
        &Client.flex_message(Cards.history_line(&1, locale), Cards.render(&1, locale))
      )

    carousel =
      case plan.shown do
        [] ->
          []

        shown ->
          alt_text = Enum.map_join(shown, "\n", &Cards.history_line({:draft, &1}, locale))
          [Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))]
      end

    attach_choices(texts ++ cards ++ carousel, turn.choices, locale)
  end

  @spec history_text(Turn.t(), [Draft.t()], String.t()) :: String.t() | nil
  def history_text(%Turn{} = turn, drafts, locale) do
    plan = plan(turn, drafts, locale)

    lines =
      Enum.map(plan.cards, &Cards.history_line(&1, locale)) ++
        Enum.map(drafts, &Cards.history_line({:draft, &1}, locale)) ++
        choices_line(turn.choices, locale)

    if lines == [], do: nil, else: Enum.join(lines, "\n")
  end

  defp plan(turn, drafts, locale) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)
    text = text(turn.text, length(hidden), locale)
    used = if(text, do: 1, else: 0) + if(shown == [], do: 0, else: 1)

    %{text: text, shown: shown, cards: Enum.take(turn.cards, max(@max_messages - used, 0))}
  end

  defp text(text, hidden, locale) do
    more = if hidden > 0, do: Labels.t(:more_drafts, locale, count: hidden)

    case Enum.reject([text, more], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> parts |> Enum.join("\n\n") |> String.slice(0, @max_text)
    end
  end

  defp attach_choices(messages, [], _locale), do: messages

  defp attach_choices([], choices, locale),
    do: attach_choices([Client.text_message(Labels.t(:choose, locale))], choices, locale)

  defp attach_choices(messages, choices, _locale) do
    quick_reply = %{
      items:
        Enum.map(choices, &%{type: "action", action: %{type: "message", label: &1, text: &1}})
    }

    List.update_at(messages, -1, &Map.put(&1, :quickReply, quick_reply))
  end

  defp choices_line([], _locale), do: []

  defp choices_line(choices, locale),
    do: ["[#{Labels.t(:options, locale)}] #{Enum.join(choices, " / ")}"]
end
