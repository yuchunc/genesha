defmodule Ganesha.Line.Cards do
  @moduledoc """
  The Draft card (chat-first replies spec §2): one sentence and 確認 / 捨棄.
  A request card (`signup_request`, `makeup_request`) leads with its shortcut,
  「幫他報名」 / 「幫他補課」, and relabels 確認 as 「已處理」, since confirming
  it only acknowledges (spec 2026-10-07 §4).

  The member notice (spec 2026-10-19-november-launch-design.md §2) tells the
  teachers a LINE group member became, or might be, a Student, with undo
  buttons.
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.Labels

  @max_bubbles 12

  # Request kind => the postback action and label of its shortcut button.
  @shortcuts %{
    "signup_request" => {"enroll_from_request", :enroll_from_request},
    "makeup_request" => {"book_from_request", :book_from_request}
  }

  @doc "A Draft as one sentence with its buttons (chat-first replies spec §2)."
  @spec draft_bubble(Draft.t(), String.t()) :: map()
  def draft_bubble(%Draft{} = draft, locale) do
    buttons =
      shortcut_buttons(draft, locale) ++
        [
          button("primary", %{
            type: "postback",
            label: Labels.t(confirm_label(draft), locale),
            data: "action=confirm&draft_id=#{draft.id}"
          }),
          button("secondary", %{
            type: "postback",
            label: Labels.t(:discard, locale),
            data: "action=discard&draft_id=#{draft.id}"
          })
        ]

    bubble([Assistant.draft_summary(draft, locale)], buttons)
  end

  @doc """
  The member notice for `Ganesha.Assistant.MemberNoticeWorker.args/3`: its
  text, then the answers she can tap (spec 2026-10-19-november-launch-design.md §2).
  """
  @spec member_notice(map(), String.t()) :: map()
  def member_notice(%{"kind" => kind} = args, locale) do
    bubble(member_texts(kind, args, locale), member_buttons(kind, args, locale))
  end

  defp member_texts("created", args, locale),
    do: [
      Labels.t(:member_created, locale,
        name: args["student_name"],
        line_name: args["display_name"]
      )
    ]

  defp member_texts("linked", args, locale),
    do: [
      Labels.t(:member_linked, locale,
        name: args["student_name"],
        line_name: args["display_name"]
      )
    ]

  defp member_texts("unsure", %{"more" => more} = args, locale) do
    question = Labels.t(:member_unsure, locale, line_name: args["display_name"])

    if more > 0,
      do: [question, Labels.t(:member_more, locale, count: more)],
      else: [question]
  end

  defp member_buttons("created", %{"student_id" => sid} = args, locale),
    do: [
      member_button("secondary", :member_not_student, locale, "member_not_student", args,
        from: "created",
        sid: sid
      )
    ]

  defp member_buttons("linked", %{"student_id" => sid} = args, locale) do
    [
      member_button("secondary", :member_not_student, locale, "member_not_student", args,
        from: "linked",
        sid: sid
      ),
      member_button("secondary", :member_wrong_link, locale, "member_wrong_link", args, sid: sid)
    ]
  end

  defp member_buttons("unsure", %{"candidates" => candidates} = args, locale) do
    picks =
      for %{"id" => sid, "name" => name} <- candidates do
        button("primary", %{
          type: "postback",
          label: name,
          data: member_postback("member_pick", args, sid: sid)
        })
      end

    picks ++
      [
        member_button("secondary", :member_new, locale, "member_new", args, []),
        member_button("secondary", :member_not_student, locale, "member_not_student", args,
          from: "unsure"
        )
      ]
  end

  defp member_button(style, label, locale, action, args, extra) do
    button(style, %{
      type: "postback",
      label: Labels.t(label, locale),
      data: member_postback(action, args, extra)
    })
  end

  @doc """
  A member notice button's postback data: `action`, the LINE user id as
  `uid`, the LINE name as `name` (cut to 20 graphemes so the data stays under
  LINE's 300 characters), then `extra` (`from`, `sid`) as given.
  """
  @spec member_postback(String.t(), map(), keyword()) :: String.t()
  def member_postback(action, %{"line_user_id" => uid, "display_name" => name}, extra \\ []) do
    URI.encode_query([action: action, uid: uid, name: String.slice(name, 0, 20)] ++ extra)
  end

  defp bubble(texts, buttons) do
    %{
      type: "bubble",
      size: "kilo",
      body: %{
        type: "box",
        layout: "vertical",
        contents: Enum.map(texts, &%{type: "text", text: &1, wrap: true})
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

  defp shortcut_buttons(%Draft{kind: kind, id: id}, locale) when is_map_key(@shortcuts, kind) do
    {action, label} = Map.fetch!(@shortcuts, kind)

    [
      button("primary", %{
        type: "postback",
        label: Labels.t(label, locale),
        data: "action=#{action}&draft_id=#{id}"
      })
    ]
  end

  defp shortcut_buttons(_draft, _locale), do: []

  defp confirm_label(%Draft{kind: kind}) when is_map_key(@shortcuts, kind), do: :handled
  defp confirm_label(_draft), do: :confirm

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
