defmodule Ganesha.Line.Cards do
  @moduledoc """
  The fixed LINE card designs (spec §2 rule 6, §6.2). The model picks a card;
  this module lays it out from stored values only. Slice 1 has the Draft card
  and the Draft carousel; the lookup cards arrive in slice 2.
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Labels

  @max_bubbles 12

  @spec render(Ganesha.Assistant.Task.card(), String.t()) :: map()
  def render({:draft, %Draft{} = draft}, locale) do
    description = Assistant.describe_draft(draft, locale)

    %{
      type: "bubble",
      header: %{
        type: "box",
        layout: "vertical",
        contents: [%{type: "text", text: description.title, weight: "bold", wrap: true}]
      },
      footer: footer(draft, description.web_path, locale)
    }
    |> put_body(description.lines ++ Enum.map(description.changes, &change_line/1))
  end

  @spec history_line(Ganesha.Assistant.Task.card(), String.t()) :: String.t()
  def history_line({:draft, %Draft{} = draft}, locale) do
    title = Assistant.describe_draft(draft, locale).title
    "[#{Labels.t(:draft, locale)} ##{draft.id} #{Labels.t(:pending, locale)}] #{title}"
  end

  @spec draft_carousel([Draft.t()], String.t()) :: map()
  def draft_carousel(drafts, locale) do
    %{
      type: "carousel",
      contents: drafts |> Enum.take(@max_bubbles) |> Enum.map(&render({:draft, &1}, locale))
    }
  end

  defp change_line({label, nil, after_value}), do: "#{label}: #{after_value}"
  defp change_line({label, before, after_value}), do: "#{label}: #{before} → #{after_value}"

  # LINE rejects a box with no contents, so a card with nothing to list has no body.
  defp put_body(bubble, []), do: bubble

  defp put_body(bubble, lines) do
    Map.put(bubble, :body, %{
      type: "box",
      layout: "vertical",
      spacing: "sm",
      contents: Enum.map(lines, &%{type: "text", text: &1, size: "sm", wrap: true})
    })
  end

  defp footer(draft, web_path, locale) do
    buttons =
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
      ] ++ web_button(web_path, locale)

    %{type: "box", layout: "vertical", spacing: "sm", contents: buttons}
  end

  defp web_button(nil, _locale), do: []

  defp web_button(path, locale) do
    [
      button("link", %{
        type: "uri",
        label: Labels.t(:open_web, locale),
        uri: GaneshaWeb.Endpoint.url() <> path
      })
    ]
  end

  defp button(style, action), do: %{type: "button", style: style, height: "sm", action: action}
end
