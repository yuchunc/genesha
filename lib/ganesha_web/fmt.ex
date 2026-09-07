defmodule GaneshaWeb.Fmt do
  @moduledoc """
  Display formatting for the ledger UI. Traditional Chinese, Taipei dates.

  Kept in the web layer: these are presentation decisions, not domain facts.
  """

  @weekday_glyphs %{1 => "一", 2 => "二", 3 => "三", 4 => "四", 5 => "五", 6 => "六", 7 => "日"}

  @doc """
  The weekday as a single character, for the slot seal.

      iex> GaneshaWeb.Fmt.weekday_glyph(1)
      "一"
  """
  def weekday_glyph(weekday) when is_integer(weekday), do: Map.fetch!(@weekday_glyphs, weekday)
  def weekday_glyph(%Date{} = date), do: date |> Date.day_of_week() |> weekday_glyph()

  @doc "The weekday spelled out, e.g. `週六`."
  def weekday(term), do: "週" <> weekday_glyph(term)

  @doc """
  A slot's label with its `週X` token removed.

  The seal beside the label already carries the weekday, so repeating it in the
  text is noise. Labels without the token pass through untouched.

      iex> GaneshaWeb.Fmt.slot_title("早晨練習｜週一 基礎瑜伽")
      "早晨練習｜基礎瑜伽"
  """
  def slot_title(label) when is_binary(label) do
    label
    |> String.replace(~r/週[一二三四五六日]\s*/u, "")
    |> String.trim()
    |> String.replace(~r/｜\s*$/u, "")
  end

  def slot_title(nil), do: ""

  @doc "`9月6日`."
  def date(%Date{} = date), do: "#{date.month}月#{date.day}日"

  @doc "`9/6`, as she writes it."
  def short_date(%Date{} = date), do: "#{date.month}/#{date.day}"

  @doc "`9月6日 週六`."
  def date_with_weekday(%Date{} = date), do: "#{date(date)} #{weekday(date)}"

  @doc "`2026年9月`."
  def month_title(%Date{} = month), do: "#{month.year}年#{month.month}月"

  @doc "`9:30`."
  def time(%Time{} = time) do
    "#{time.hour}:#{time.minute |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "`9:30–10:45` with an en dash."
  def time_range(%Time{} = from, %Time{} = to), do: "#{time(from)}–#{time(to)}"

  @doc """
  Thousands-separated integer TWD. Money is never a float in this app.

      iex> GaneshaWeb.Fmt.amount(0)
      "0"
      iex> GaneshaWeb.Fmt.amount(600)
      "600"
      iex> GaneshaWeb.Fmt.amount(1600)
      "1,600"
      iex> GaneshaWeb.Fmt.amount(18400)
      "18,400"
      iex> GaneshaWeb.Fmt.amount(50_000)
      "50,000"
  """
  def amount(n) when is_integer(n) do
    n
    |> abs()
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&(&1 |> Enum.reverse() |> List.to_string()))
    |> Enum.reverse()
    |> Enum.join(",")
    |> then(&if(n < 0, do: "−" <> &1, else: &1))
  end

  @doc """
  How far off a date is, in the words she would use.

      iex> GaneshaWeb.Fmt.relative_day(~D[2026-09-06], ~D[2026-09-06])
      "今天"
  """
  def relative_day(%Date{} = date, %Date{} = today) do
    case Date.diff(date, today) do
      0 -> "今天"
      1 -> "明天"
      2 -> "後天"
      -1 -> "昨天"
      d when d > 2 and d < 7 -> "#{d} 天後"
      d when d < -1 -> "#{abs(d)} 天前"
      _ -> date_with_weekday(date)
    end
  end

  @doc "The Chinese name of an attendance kind."
  def kind("enrolled"), do: "月課程"
  def kind("makeup"), do: "補課"
  def kind("drop_in"), do: "單堂"
  def kind("trial"), do: "體驗"
  def kind(other) when is_binary(other), do: other

  @doc "The Chinese name of a payment method."
  def method("line_pay"), do: "Line Pay"
  def method("line_bank"), do: "LINE Bank"
  def method("cash"), do: "現金"
  def method("other"), do: "其他"
  def method(other) when is_binary(other), do: other

  @doc "The Chinese name of a payment state."
  def payment_state("claimed"), do: "待確認"
  def payment_state("confirmed"), do: "已確認"
  def payment_state("disputed"), do: "有疑義"
  def payment_state(other) when is_binary(other), do: other
end
