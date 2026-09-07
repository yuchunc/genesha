defmodule Ganesha.Publishing do
  @moduledoc """
  Renders the monthly announcement she posts to LINE.

  The output deliberately mirrors the formatting of her hand-written document so
  the message looks unchanged to her students. Nothing here sends anything: a
  push into a 25-person group would cost 25 of the 200 free monthly messages,
  and the bot is not customer-facing. She copies the text and posts it herself.
  """

  import Ecto.Query, warn: false
  alias Ganesha.{Catalog, Repo, Roster, Studio}
  alias Ganesha.Publishing.Settings

  # Blank numbered places in the copy-and-paste signup list.
  @places 6

  def get_settings do
    Repo.one(from s in Settings, limit: 1) || %Settings{}
  end

  def update_settings(attrs) do
    get_settings() |> Settings.changeset(attrs) |> Repo.insert_or_update()
  end

  def change_settings(%Settings{} = settings, attrs \\ %{}) do
    Settings.changeset(settings, attrs)
  end

  @doc "The ✨開課時間表 block: one entry per active slot with its dates and price."
  def schedule_block(%Date{} = month) do
    price = monthly_price_per_class()

    entries =
      Studio.list_active_slots()
      |> Enum.map(&slot_entry(&1, month, price))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    "✨ #{month.month}月開課時間表\n\n" <> entries
  end

  defp slot_entry(slot, month, price) do
    sessions =
      slot
      |> Studio.sessions_for_slot_in_month(month)
      |> Enum.filter(&(&1.state == "scheduled"))

    if sessions == [] do
      nil
    else
      dates = Enum.map_join(sessions, "、", &format_date(&1, slot))
      count = length(sessions)

      String.trim_trailing("""
      #{slot.label}
      時間：#{format_time(slot.start_time)}－#{format_time(slot.end_time)}
      日期：#{dates}
      （#{count * price}元 /#{count} 堂）
      """)
    end
  end

  # A session whose style differs from its slot default is marked with a leading
  # asterisk and the style name, exactly as "*基礎8/26" in her document.
  defp format_date(session, slot) do
    if session.style == slot.default_style do
      short_date(session.date)
    else
      "*#{session.style}#{short_date(session.date)}"
    end
  end

  defp short_date(%Date{} = date), do: "#{date.month}/#{date.day}"

  defp format_time(%Time{} = time) do
    minute = time.minute |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{time.hour}:#{minute}"
  end

  # Slots are published as the monthly package; drop-ins are not advertised.
  defp monthly_price_per_class do
    case Enum.find(Catalog.list_active_packages(), &(&1.kind == "monthly")) do
      nil -> 0
      package -> package.price_per_class
    end
  end

  @doc "The copy-and-paste signup list: numbered places plus an 其他 section."
  def signup_block(%Date{} = _month) do
    intro = "參加月課程的yogi，\n請寫下姓名，\n並複製貼上以便統計。"

    blocks =
      Enum.map_join(Studio.list_active_slots(), "\n\n", fn slot ->
        places = Enum.map_join(1..@places, "\n", &"#{&1}.")
        "#{slot.label}：\n#{places}\n\n其他："
      end)

    intro <> "\n\n" <> blocks
  end

  @doc "Her own reference block: who is on each date, with makeups and drop-ins marked."
  def roster_block(%Date{} = month) do
    Enum.map_join(Studio.list_active_slots(), "\n\n", fn slot ->
      lines =
        slot
        |> Studio.sessions_for_slot_in_month(month)
        |> Enum.filter(&(&1.state == "scheduled"))
        |> Enum.map_join("\n", fn session ->
          names =
            session
            |> Roster.list_for_session()
            |> Enum.map_join("、", &attendee_name/1)

          "#{short_date(session.date)}：#{names}"
        end)

      "#{slot.label}\n#{lines}"
    end)
  end

  # Kind and state are independent: a drop-in or a makeup can also be a
  # no-show, and both markers must survive rather than one short-circuiting
  # the other.
  defp attendee_name(attendance), do: kind_marker(attendance) <> no_show_marker(attendance)

  defp kind_marker(%{kind: "drop_in"} = a), do: "（單）#{a.student.display_name}"
  defp kind_marker(%{kind: "makeup"} = a), do: "#{a.student.display_name}（補課#{note_suffix(a)}）"
  defp kind_marker(%{kind: "trial"} = a), do: "#{a.student.display_name}（體驗）"
  defp kind_marker(a), do: a.student.display_name

  defp no_show_marker(%{state: "no_show"}), do: "（未到）"
  defp no_show_marker(_), do: ""

  defp note_suffix(%{note: nil}), do: ""
  defp note_suffix(%{note: ""}), do: ""
  defp note_suffix(%{note: note}), do: " #{note}"

  @doc "The full message: schedule, signup list, and the transfer footer."
  def announcement(%Date{} = month) do
    settings = get_settings()

    footer =
      [deadline_line(settings), bank_lines(settings), settings.closing_note]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    [schedule_block(month), separator(), signup_block(month)]
    |> then(fn parts -> if footer == "", do: parts, else: parts ++ [separator(), footer] end)
    |> Enum.join("\n\n")
  end

  defp separator, do: "——————————————————"

  defp deadline_line(%Settings{transfer_deadline: nil}), do: nil
  defp deadline_line(%Settings{transfer_deadline: ""}), do: nil

  defp deadline_line(%Settings{transfer_deadline: deadline}) do
    "麻煩於#{deadline}前轉帳，並告知帳後五碼。"
  end

  defp bank_lines(%Settings{} = settings) do
    [bank_line(settings), account_line(settings)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp bank_line(%Settings{bank_code: nil}), do: nil
  defp bank_line(%Settings{bank_code: ""}), do: nil

  defp bank_line(%Settings{} = s),
    do: String.trim_trailing("LINE Bank 銀行代號：#{s.bank_code} #{s.bank_name}")

  defp account_line(%Settings{account_number: nil}), do: nil
  defp account_line(%Settings{account_number: ""}), do: nil
  defp account_line(%Settings{} = s), do: "帳號： #{s.account_number}"
end
