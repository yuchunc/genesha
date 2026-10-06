defmodule Ganesha.Line.Cards do
  @moduledoc """
  The Draft card (chat-first replies spec §2): one sentence and 確認 / 捨棄,
  plus 「幫他報名」 first on a sign-up request (spec 2026-10-06 §5).
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Labels

  @max_bubbles 12

  @doc "A Draft as one sentence with its buttons (chat-first replies spec §2)."
  @spec draft_bubble(Draft.t(), String.t()) :: map()
  def draft_bubble(%Draft{} = draft, locale) do
    buttons =
      shortcut_buttons(draft, locale) ++
        [
          button("primary", %{
            type: "postback",
            label: Labels.t(:confirm, locale),
            data: "action=confirm&draft_id=#{draft.id}"
          }),
          button("secondary", %{
            type: "postback",
            label: Labels.t(:discard, locale),
            data: "action=discard&draft_id=#{draft.id}"
          })
        ]

    %{
      type: "bubble",
      size: "kilo",
      body: %{
        type: "box",
        layout: "vertical",
        contents: [%{type: "text", text: Assistant.draft_summary(draft, locale), wrap: true}]
      },
      footer: %{
        type: "box",
        # Three buttons do not fit side by side in a kilo bubble.
        layout: if(length(buttons) > 2, do: "vertical", else: "horizontal"),
        spacing: "sm",
        contents: buttons
      }
    }
  end

  defp shortcut_buttons(%Draft{kind: "signup_request", id: id}, locale) do
    [
      button("primary", %{
        type: "postback",
        label: Labels.t(:enroll_from_request, locale),
        data: "action=enroll_from_request&draft_id=#{id}"
      })
    ]
  end

  defp shortcut_buttons(_draft, _locale), do: []

  @doc "The line recorded in the chat history for a Draft card she was shown."
  @spec history_line({:draft, Draft.t()}, String.t()) :: String.t()
  def history_line({:draft, %Draft{} = draft}, locale) do
    "[#{Labels.t(:draft, locale)} ##{draft.id} #{Labels.t(:pending, locale)}] #{Assistant.draft_summary(draft, locale)}"
  end

  @spec draft_carousel([Draft.t()], String.t()) :: map()
  def draft_carousel(drafts, locale) do
    %{
      type: "carousel",
      contents: drafts |> Enum.take(@max_bubbles) |> Enum.map(&draft_bubble(&1, locale))
    }
  end

  defp button(style, action), do: %{type: "button", style: style, height: "sm", action: action}
end
