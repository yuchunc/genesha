defmodule Ganesha.Assistant.SummaryTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Summary

  test "day/2 reads an ISO date in each locale and tolerates junk" do
    assert Summary.day("2026-10-08", "zh-TW") == "10/8 週四"
    assert Summary.day("2026-10-08", "en") == "Thu 10/8"
    assert Summary.day(nil, "zh-TW") == ""
    assert Summary.day("nope", "en") == ""
  end

  test "time_range/2 reads ISO times or passes a display range through" do
    assert Summary.time_range("19:00:00", "20:15:00") == "19:00–20:15"
    assert Summary.time_range("19:00–20:15", nil) == "19:00–20:15"
    assert Summary.time_range(nil, nil) == ""
  end

  test "words/1 drops blanks; paren/2 wraps per locale" do
    assert Summary.words(["a", nil, "", "b"]) == "a b"
    assert Summary.paren(["LINE Pay", "10/3"], "zh-TW") == "（LINE Pay，10/3）"
    assert Summary.paren(["LINE Pay", nil], "en") == " (LINE Pay)"
    assert Summary.paren([nil, ""], "en") == ""
  end

  test "month_name/2, weekday/2, method/2 and kind/2 speak both languages" do
    assert Summary.month_name("2026-10", "zh-TW") == "10月"
    assert Summary.month_name("2026-10-01", "en") == "October"
    assert Summary.weekday(3, "zh-TW") == "週三"
    assert Summary.weekday(3, "en") == "Wed"
    assert Summary.method("cash", "zh-TW") == "現金"
    assert Summary.method("cash", "en") == "cash"
    assert Summary.kind("drop_in", "zh-TW") == "單堂"
    assert Summary.kind("trial", "en") == "trial"
  end
end
