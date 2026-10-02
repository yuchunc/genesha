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
end
