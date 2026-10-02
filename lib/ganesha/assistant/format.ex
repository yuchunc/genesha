defmodule Ganesha.Assistant.Format do
  @moduledoc "Value formatting shared by the assistant tasks' `describe/2`."

  alias GaneshaWeb.Fmt

  @doc """
  An amount as a Draft card shows it, e.g. `NT$1,600`; anything that is not
  a whole-dollar integer is shown as given.
  """
  def money(n) when is_integer(n), do: "NT$" <> Fmt.amount(n)
  def money(other), do: to_string(other)
end
