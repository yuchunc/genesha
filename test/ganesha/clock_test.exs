defmodule Ganesha.ClockTest do
  use ExUnit.Case, async: true
  alias Ganesha.Clock

  test "to_taipei_date/1 rolls over before UTC midnight" do
    # 17:00 UTC on 8/31 is already 01:00 on 9/1 in Taipei (UTC+8).
    assert Clock.to_taipei_date(~U[2026-08-31 17:00:00Z]) == ~D[2026-09-01]
  end

  test "to_taipei_date/1 keeps the same date early in the UTC day" do
    assert Clock.to_taipei_date(~U[2026-08-31 03:00:00Z]) == ~D[2026-08-31]
  end

  test "today/1 returns the Taipei calendar date for a pinned UTC instant" do
    assert Clock.today(~U[2026-08-31 17:00:00Z]) == ~D[2026-09-01]
  end

  test "today/0 is either the UTC date or the day after" do
    assert Clock.today() in [Date.utc_today(), Date.add(Date.utc_today(), 1)]
  end

  test "end_of_month/1 returns the last day of that month" do
    assert Clock.end_of_month(~D[2026-08-17]) == ~D[2026-08-31]
    assert Clock.end_of_month(~D[2026-02-03]) == ~D[2026-02-28]
  end
end
