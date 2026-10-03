defmodule Ganesha.Assistant.Format do
  @moduledoc "Value formatting shared by the assistant tasks' `describe/2` and the LINE cards."

  alias GaneshaWeb.Fmt

  @doc """
  An amount as a Draft card shows it, e.g. `NT$1,600`; anything that is not
  a whole-dollar integer is shown as given.
  """
  def money(n) when is_integer(n), do: "NT$" <> Fmt.amount(n)
  def money(other), do: to_string(other)

  @doc "A Session's day as she reads it: `10/7 週三`, or `Wed 10/7` in English; `\"\"` for nil."
  @spec session_day(Date.t() | nil, String.t() | nil) :: String.t()
  def session_day(nil, _locale), do: ""

  def session_day(%Date{} = date, "en"),
    do: "#{Calendar.strftime(date, "%a")} #{Fmt.short_date(date)}"

  def session_day(%Date{} = date, _locale), do: "#{Fmt.short_date(date)} #{Fmt.weekday(date)}"

  @doc "A month's title: `2026年10月`, or `October 2026` in English."
  @spec month_title(Date.t(), String.t() | nil) :: String.t()
  def month_title(%Date{} = month, "en"), do: Calendar.strftime(month, "%B %Y")
  def month_title(%Date{} = month, _locale), do: Fmt.month_title(month)
end
