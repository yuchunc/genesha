defmodule GaneshaWeb.FmtTest do
  use ExUnit.Case, async: true
  alias GaneshaWeb.Fmt

  doctest GaneshaWeb.Fmt

  describe "session_label/1 and session_time_range/1" do
    test "read from the slot for a recurring session" do
      session = %{
        slot: %{label: "早晨練習｜週一 基礎瑜伽", start_time: ~T[09:30:00], end_time: ~T[10:45:00]},
        label: nil,
        start_time: nil,
        end_time: nil
      }

      assert Fmt.session_label(session) == "早晨練習｜基礎瑜伽"
      assert Fmt.session_time_range(session) == "9:30–10:45"
    end

    test "read from the session itself when standalone" do
      session = %{slot: nil, label: "期間限定：中秋瑜伽", start_time: ~T[19:00:00], end_time: ~T[20:00:00]}

      assert Fmt.session_label(session) == "期間限定：中秋瑜伽"
      assert Fmt.session_time_range(session) == "19:00–20:00"
    end
  end
end
