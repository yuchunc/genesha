defmodule Ganesha.Clock do
  @moduledoc """
  Taipei-local dates.

  Taiwan observes no daylight saving time, so UTC+8 is a fixed offset. Using a
  fixed offset avoids adding a timezone database dependency (`DateTime.now!/2`
  would require one) and is exact for this locale.

  Every date shown to the user, and every date used in a business rule —
  notably credit expiry — MUST come from here rather than `Date.utc_today/0`.
  Expiring a credit on a UTC month boundary would kill it eight hours early.
  """

  @offset_seconds 8 * 60 * 60

  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  @spec today() :: Date.t()
  def today, do: to_taipei_date(now())

  @spec to_taipei_date(DateTime.t()) :: Date.t()
  def to_taipei_date(%DateTime{} = utc) do
    utc |> DateTime.add(@offset_seconds, :second) |> DateTime.to_date()
  end

  @spec end_of_month(Date.t()) :: Date.t()
  def end_of_month(%Date{} = date), do: Date.end_of_month(date)
end
