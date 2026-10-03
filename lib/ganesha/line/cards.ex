defmodule Ganesha.Line.Cards do
  @moduledoc """
  The fixed LINE card designs (spec §2 rule 6, §6.2). The model picks a card;
  this module lays it out from stored values only.

  LINE rejects a Flex message with an empty text or a box with no contents, so
  every card always has at least one body line and blank values fall back to a
  label. Long lists stop at a cap and end with a row naming how many were left out.
  """

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Draft, Format}
  alias Ganesha.Line.Labels

  @max_bubbles 12
  @max_rows 10
  @max_attendees 20

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

  def render({:session, payload}, locale) when is_map(payload) do
    lookup_bubble(
      present(payload["title"]) || Labels.t(:card_session, locale),
      session_lines(payload, locale)
    )
  end

  def render({:month, payload}, locale) when is_map(payload) do
    count = payload["session_count"] || 0

    lookup_bubble(
      Labels.t(:schedule_title, locale, month: payload["month"] || ""),
      [Labels.t(:sessions_count, locale, count: count) | month_lines(payload, locale)]
    )
  end

  def render({:money, payload}, locale) when is_map(payload) do
    lookup_bubble(
      Labels.t(:money_title, locale, month: payload["month"] || ""),
      money_lines(payload, locale)
    )
  end

  def render({:student, payload}, locale) when is_map(payload) do
    lookup_bubble(
      "#{Labels.t(:card_student, locale)} #{present(payload["name"]) || "?"}",
      student_lines(payload, locale)
    )
  end

  def render({:credits, payload}, locale) when is_map(payload) do
    lookup_bubble(Labels.t(:credits_title, locale), credits_lines(payload, locale))
  end

  @spec history_line(Ganesha.Assistant.Task.card(), String.t()) :: String.t()
  def history_line({:draft, %Draft{} = draft}, locale) do
    title = Assistant.describe_draft(draft, locale).title
    "[#{Labels.t(:draft, locale)} ##{draft.id} #{Labels.t(:pending, locale)}] #{title}"
  end

  def history_line({:session, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_session, locale)}] #{present(payload["title"]) || "?"}"
  end

  def history_line({:month, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_month, locale)}] #{present(payload["month"]) || "?"}"
  end

  def history_line({:money, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_money, locale)}] #{present(payload["month"]) || "?"}"
  end

  def history_line({:student, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_student, locale)}] #{present(payload["name"]) || "?"}"
  end

  def history_line({:credits, payload}, locale) when is_map(payload) do
    "[#{Labels.t(:card_credits, locale)}] #{payload["count"] || 0}"
  end

  @spec draft_carousel([Draft.t()], String.t()) :: map()
  def draft_carousel(drafts, locale) do
    %{
      type: "carousel",
      contents: drafts |> Enum.take(@max_bubbles) |> Enum.map(&render({:draft, &1}, locale))
    }
  end

  @doc """
  Sample cards for `mix line.validate_cards` (spec §8): every card type, and each
  lookup card once more with nothing to list.
  """
  @spec samples(String.t()) :: [Ganesha.Assistant.Task.card()]
  def samples(locale) do
    month = Format.month_title(~D[2026-10-01], locale)
    day = Format.session_day(~D[2026-10-07], locale)
    later = Format.session_day(~D[2026-10-14], locale)

    session = %{
      "title" => "#{day} 基礎 19:00–20:15",
      "style" => "Hatha",
      "count" => 2,
      "cancelled" => false,
      "attendees" => [
        %{"name" => "Lulu", "kind" => "enrolled", "no_show" => false},
        %{"name" => "Amy", "kind" => "drop_in", "no_show" => true}
      ]
    }

    [
      {:session, session},
      {:session, %{session | "count" => 0, "cancelled" => true, "attendees" => []}},
      {:month,
       %{
         "month" => month,
         "session_count" => 2,
         "rows" => [
           %{"day" => day, "label" => "基礎", "time" => "19:00", "count" => 2},
           %{"day" => later, "label" => "基礎", "time" => "19:00", "count" => 1}
         ]
       }},
      {:month, %{"month" => month, "session_count" => 0, "rows" => []}},
      {:money,
       %{
         "month" => month,
         "revenue" => Format.money(48_000),
         "tax_warn" => true,
         "owed_total" => Format.money(3200),
         "debtors" => [%{"name" => "Amy", "amount" => Format.money(3200)}]
       }},
      {:money,
       %{
         "month" => month,
         "revenue" => Format.money(0),
         "tax_warn" => false,
         "owed_total" => Format.money(0),
         "debtors" => []
       }},
      {:student,
       %{
         "name" => "Lulu",
         "owed" => Format.money(1600),
         "purchases" => [
           %{
             "package" => "月課程",
             "paid" => Format.money(1600),
             "payable" => Format.money(3200)
           }
         ],
         "upcoming" => [%{"day" => day, "label" => "基礎"}],
         "credits" => 1
       }},
      {:student,
       %{
         "name" => "Amy",
         "owed" => Format.money(0),
         "purchases" => [],
         "upcoming" => [],
         "credits" => 0
       }},
      {:credits,
       %{
         "count" => 2,
         "expiring_count" => 1,
         "rows" => [
           %{"student" => "Lulu", "source" => "package", "expires" => later},
           %{"student" => "Amy", "source" => "cancellation", "expires" => nil}
         ]
       }},
      {:credits, %{"count" => 0, "expiring_count" => 0, "rows" => []}},
      {:draft,
       %Draft{
         id: 1,
         kind: "record_payment",
         state: "pending",
         parsed: %{
           "student_id" => 1,
           "student_name" => "Lulu",
           "amount" => 3200,
           "method" => "line_pay",
           "paid_on" => "2026-10-02",
           "package_name" => "月課程",
           "before_owed" => 3200
         }
       }}
    ]
  end

  defp session_lines(payload, locale) do
    summary =
      Enum.reject(
        [
          present(payload["style"]),
          Labels.t(:roster_count, locale, count: payload["count"] || 0),
          if(payload["cancelled"], do: Labels.t(:cancelled, locale))
        ],
        &is_nil/1
      )

    case payload["attendees"] || [] do
      [] ->
        summary ++ [Labels.t(:no_one_booked, locale)]

      attendees ->
        summary ++ capped(attendees, @max_attendees, locale, &attendee_line(&1, locale))
    end
  end

  defp attendee_line(attendee, locale) do
    name = present(attendee["name"]) || "?"

    kind =
      case attendee["kind"] do
        nil -> ""
        kind -> " · #{kind_label(kind, locale)}"
      end

    no_show = if attendee["no_show"], do: " (#{Labels.t(:no_show, locale)})", else: ""
    name <> kind <> no_show
  end

  defp month_lines(payload, locale) do
    case payload["rows"] || [] do
      [] ->
        [Labels.t(:no_sessions, locale)]

      rows ->
        capped(rows, @max_rows, locale, fn row ->
          when_line = Enum.join([row["day"] || "?", row["label"], row["time"]], " ")
          "#{when_line} · #{Labels.t(:booked_count, locale, count: row["count"] || 0)}"
        end)
    end
  end

  defp money_lines(payload, locale) do
    revenue = ["#{Labels.t(:revenue, locale)}: #{payload["revenue"] || Format.money(0)}"]

    tax =
      if payload["tax_warn"],
        do: ["#{Labels.t(:tax_threshold, locale)}: #{Labels.t(:tax_warn, locale)}"],
        else: []

    owed =
      case payload["debtors"] || [] do
        [] ->
          [Labels.t(:nothing_owed, locale)]

        debtors ->
          owed_total = payload["owed_total"] || Format.money(0)

          [Labels.t(:owed_total, locale, amount: owed_total)] ++
            capped(debtors, @max_rows, locale, &"#{&1["name"]}: #{&1["amount"]}")
      end

    revenue ++ tax ++ owed
  end

  defp student_lines(payload, locale) do
    owed = payload["owed"] || Format.money(0)

    owed_line =
      if owed == Format.money(0),
        do: Labels.t(:paid_up, locale),
        else: Labels.t(:owes, locale, amount: owed)

    purchases =
      section(payload["purchases"], :purchases, locale, fn p ->
        "#{p["package"]}: #{Labels.t(:paid_of, locale, paid: p["paid"], payable: p["payable"])}"
      end)

    upcoming =
      section(payload["upcoming"], :upcoming, locale, &"#{&1["day"]} #{&1["label"]}")

    credits =
      case payload["credits"] do
        count when is_integer(count) and count > 0 ->
          [Labels.t(:credits_heading, locale, count: count)]

        _none ->
          []
      end

    [owed_line] ++ purchases ++ upcoming ++ credits
  end

  defp section(rows, _heading, _locale, _fun) when rows in [nil, []], do: []

  defp section(rows, heading, locale, fun),
    do: [Labels.t(heading, locale) | capped(rows, @max_rows, locale, fun)]

  defp credits_lines(payload, locale) do
    case payload["count"] || 0 do
      0 ->
        [Labels.t(:no_credits, locale)]

      count ->
        expiring = payload["expiring_count"] || 0

        [Labels.t(:credits_count, locale, count: count, expiring: expiring)] ++
          capped(payload["rows"] || [], @max_rows, locale, &credit_line(&1, locale))
    end
  end

  defp credit_line(credit, locale) do
    source =
      case credit["source"] do
        "package" -> Labels.t(:source_package, locale)
        "cancellation" -> Labels.t(:source_cancellation, locale)
        other -> other
      end

    expiry =
      case credit["expires"] do
        nil -> Labels.t(:no_expiry, locale)
        date -> Labels.t(:expires_on, locale, date: date)
      end

    "#{credit["student"]} · #{source} · #{expiry}"
  end

  defp capped(rows, max, locale, fun) do
    {shown, hidden} = Enum.split(rows, max)

    more =
      if hidden == [], do: [], else: [Labels.t(:more_rows, locale, count: length(hidden))]

    Enum.map(shown, fun) ++ more
  end

  defp kind_label("enrolled", locale), do: Labels.t(:kind_enrolled, locale)
  defp kind_label("makeup", locale), do: Labels.t(:kind_makeup, locale)
  defp kind_label("drop_in", locale), do: Labels.t(:kind_drop_in, locale)
  defp kind_label("trial", locale), do: Labels.t(:kind_trial, locale)
  defp kind_label(other, _locale), do: other

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil

  defp lookup_bubble(title, lines) do
    %{
      type: "bubble",
      header: %{type: "box", layout: "vertical", contents: [text(title, "bold")]},
      body: body_box(lines)
    }
  end

  defp body_box(lines) do
    %{
      type: "box",
      layout: "vertical",
      spacing: "sm",
      contents: Enum.map(lines, &text(&1, "regular"))
    }
  end

  defp text(line, weight), do: %{type: "text", text: line, size: "sm", wrap: true, weight: weight}

  defp change_line({label, nil, after_value}), do: "#{label}: #{after_value}"
  defp change_line({label, before, after_value}), do: "#{label}: #{before} → #{after_value}"

  # A Draft card with nothing to list has no body (LINE rejects an empty box).
  defp put_body(bubble, []), do: bubble
  defp put_body(bubble, lines), do: Map.put(bubble, :body, body_box(lines))

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
