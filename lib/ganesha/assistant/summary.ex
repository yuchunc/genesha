defmodule Ganesha.Assistant.Summary do
  @moduledoc """
  Shared pieces of the one-sentence Draft summaries (chat-first replies spec §1).
  Every function takes the plain values a task stored in `parsed`, so a
  summary never touches the database. Blank or unreadable input yields `""`.
  """

  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @en_weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  @spec day(String.t() | nil, String.t()) :: String.t()
  def day(iso, locale) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Format.session_day(date, locale)
      {:error, _} -> ""
    end
  end

  def day(_iso, _locale), do: ""

  @doc "`19:00–20:15` from two ISO times; a display range passes through unchanged."
  @spec time_range(String.t() | nil, String.t() | nil) :: String.t()
  def time_range(from, to) when is_binary(from) and is_binary(to) do
    with {:ok, from} <- Time.from_iso8601(from),
         {:ok, to} <- Time.from_iso8601(to) do
      Fmt.time_range(from, to)
    else
      _ -> ""
    end
  end

  def time_range(range, nil) when is_binary(range), do: range
  def time_range(_from, _to), do: ""

  @spec money(term()) :: String.t()
  def money(amount), do: Format.money(amount)

  @spec words([String.t() | nil]) :: String.t()
  def words(parts), do: parts |> Enum.reject(&blank?/1) |> Enum.join(" ")

  @doc "`（a，b）` in Chinese, ` (a, b)` in English; `\"\"` when every part is blank."
  @spec paren([String.t() | nil], String.t()) :: String.t()
  def paren(parts, locale) do
    case Enum.reject(parts, &blank?/1) do
      [] -> ""
      kept when locale == "en" -> " (" <> Enum.join(kept, ", ") <> ")"
      kept -> "（" <> Enum.join(kept, "，") <> "）"
    end
  end

  @doc "`10月` / `October` from `YYYY-MM` or an ISO date."
  @spec month_name(String.t() | nil, String.t()) :: String.t()
  def month_name(value, locale) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 7) <> "-01") do
      {:ok, date} when locale == "en" -> Calendar.strftime(date, "%B")
      {:ok, date} -> "#{date.month}月"
      {:error, _} -> ""
    end
  end

  def month_name(_value, _locale), do: ""

  @spec weekday(1..7, String.t()) :: String.t()
  def weekday(n, "en") when n in 1..7, do: Enum.at(@en_weekdays, n - 1)
  def weekday(n, _locale) when n in 1..7, do: Fmt.weekday(n)
  def weekday(_n, _locale), do: ""

  @spec method(String.t() | nil, String.t()) :: String.t() | nil
  def method(nil, _locale), do: nil
  def method("line_pay", _locale), do: "LINE Pay"
  def method("line_bank", _locale), do: "LINE Bank"
  def method("cash", "en"), do: "cash"
  def method("other", "en"), do: "other"
  def method(method, "en"), do: method
  def method(method, _locale), do: Fmt.method(method)

  @doc "A Package kind: 月課程 / 單堂 / 體驗, or monthly / drop-in / trial."
  @spec kind(String.t() | nil, String.t()) :: String.t()
  def kind("monthly", "en"), do: "monthly"
  def kind("drop_in", "en"), do: "drop-in"
  def kind("trial", "en"), do: "trial"
  def kind("monthly", _locale), do: "月課程"
  def kind("drop_in", _locale), do: "單堂"
  def kind("trial", _locale), do: "體驗"
  def kind(other, _locale), do: to_string(other)

  defp blank?(value), do: value in [nil, ""]
end
