defmodule Ganesha.Line.Reply do
  @moduledoc """
  Packs a `Ganesha.Assistant.Turn` into LINE messages (chat-first replies spec §2):
  the text, then one Draft carousel. Drafts past twelve are counted in the text.
  Choices ride on the last message as quick replies.
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Draft, Turn}
  alias Ganesha.Line.{Cards, Client, Labels}

  @max_bubbles 12
  @max_text 5000

  @spec build(Turn.t(), [Draft.t()], String.t()) :: [map()]
  def build(%Turn{} = turn, drafts, locale) do
    {shown, hidden} = Enum.split(drafts, @max_bubbles)

    texts =
      case text(turn.text, length(hidden), locale) do
        nil -> []
        text -> [Client.text_message(text)]
      end

    carousel =
      case shown do
        [] ->
          []

        shown ->
          alt_text = Enum.map_join(shown, "\n", &Assistant.draft_summary(&1, locale))
          [Client.flex_message(alt_text, Cards.draft_carousel(shown, locale))]
      end

    attach_choices(texts ++ carousel, turn.choices, locale)
  end

  @spec history_text(Turn.t(), [Draft.t()], String.t()) :: String.t() | nil
  def history_text(%Turn{} = turn, drafts, locale) do
    lines =
      Enum.map(drafts, &Cards.history_line({:draft, &1}, locale)) ++
        choices_line(turn.choices, locale)

    if lines == [], do: nil, else: Enum.join(lines, "\n")
  end

  @system_tags ~w(options tag_confirmed tag_discarded tag_failed tag_already_handled tag_replaced tag_exception)a

  @doc """
  `text` without the lines only the system writes: the card lines of
  `history_text/3` (「[草稿 #41 待確認] …」, 「[選項] …」) and Confirm outcomes
  (「[已確認] 草稿 #41 …」), in either language. The model sees them in its
  history and copies them into replies, where she would read every card twice.
  """
  @spec without_system_lines(String.t() | nil) :: String.t() | nil
  def without_system_lines(nil), do: nil

  def without_system_lines(text) when is_binary(text) do
    pattern = system_line_pattern()

    text
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(pattern, &1))
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  defp system_line_pattern do
    alternatives =
      for locale <- ["zh-TW", "en"] do
        draft = Regex.escape(Labels.t(:draft, locale))
        tags = Enum.map(@system_tags, &Regex.escape(Labels.t(&1, locale)))
        ["#{draft} #\\d+[^\\]]*" | tags]
      end

    Regex.compile!("^\\s*\\[(?:#{alternatives |> List.flatten() |> Enum.join("|")})\\]", "u")
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
