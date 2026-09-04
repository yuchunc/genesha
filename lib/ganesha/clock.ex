defmodule Ganesha.Clock do
  @moduledoc """
  Taipei-local dates.

  Taiwan observes no daylight saving time, so UTC+8 is a fixed offset. Using a
  fixed offset avoids adding a timezone database dependency (`DateTime.now!/2`
  would require one) and is exact for this locale.

  `now/0` returns the current instant as **UTC** (`Etc/UTC`). `today/0` returns
  the **Taipei** calendar date for that instant. Never derive a date from `now/0`
  directly — use `today/0` or `to_taipei_date/1` instead. Shifting `now/0` by
  eight hours while keeping the `Etc/UTC` zone would mislabel the instant and
  compare wrong against Ecto's `utc_datetime` columns.

  Every date shown to the user, and every date used in a business rule —
  notably credit expiry — MUST come from here rather than `Date.utc_today/0`.
  Expiring a credit on a UTC month boundary would kill it eight hours early.
  """

  @offset_seconds 8 * 60 * 60

  @typedoc """
  UTC instant (`time_zone: "Etc/UTC"`). The function head matches this at runtime;
  other zones raise `FunctionClauseError`.
  """
  @type utc_datetime :: %DateTime{}

  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  @spec today() :: Date.t()
  @spec today(DateTime.t()) :: Date.t()
  def today(now \\ now()), do: to_taipei_date(now)

  @spec to_taipei_date(utc_datetime()) :: Date.t()
  def to_taipei_date(%DateTime{time_zone: "Etc/UTC"} = utc) do
    utc |> DateTime.add(@offset_seconds, :second) |> DateTime.to_date()
  end

  @spec end_of_month(Date.t()) :: Date.t()
  def end_of_month(%Date{} = date), do: Date.end_of_month(date)
end
