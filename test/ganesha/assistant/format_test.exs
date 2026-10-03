defmodule Ganesha.Assistant.FormatTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Format

  describe "money/1" do
    test "groups thousands only from four digits up" do
      assert Format.money(0) == "NT$0"
      assert Format.money(999) == "NT$999"
      assert Format.money(1000) == "NT$1,000"
      assert Format.money(1_234_567) == "NT$1,234,567"
    end

    test "keeps the sign of a negative amount" do
      assert Format.money(-1600) == "NT$−1,600"
    end
  end

  describe "session_day/2" do
    test "reads as she writes it, or weekday first in English" do
      assert Format.session_day(~D[2026-10-07], "zh-TW") == "10/7 週三"
      assert Format.session_day(~D[2026-10-07], "en") == "Wed 10/7"
      assert Format.session_day(~D[2026-10-07], nil) == "10/7 週三"
    end

    test "is empty for a missing date" do
      assert Format.session_day(nil, "en") == ""
    end
  end

  describe "month_title/2" do
    test "follows the chat's language" do
      assert Format.month_title(~D[2026-10-01], "zh-TW") == "2026年10月"
      assert Format.month_title(~D[2026-10-15], "en") == "October 2026"
    end
  end
end
