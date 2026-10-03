defmodule Ganesha.Assistant.Tasks.AddSlotTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.AddSlot
  alias GaneshaWeb.Fmt

  # August 2026 has five Mondays: 3, 10, 17, 24, 31.
  @input %{
    "weekday" => 1,
    "start_time" => "09:30:00",
    "end_time" => "10:45:00",
    "label" => "早晨練習｜週一 基礎瑜伽",
    "default_style" => "基礎",
    "month" => "2026-08-01"
  }

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  defp propose!(ctx, input \\ @input) do
    {:ok, %{parsed: parsed}} = AddSlot.propose(input, ctx)
    parsed
  end

  defp slot_fixture(attrs) do
    {:ok, slot} =
      Studio.create_slot(
        Map.merge(
          %{
            weekday: 1,
            start_time: ~T[09:30:00],
            end_time: ~T[10:45:00],
            default_style: "流動",
            label: "既有班"
          },
          attrs
        )
      )

    slot
  end

  describe "propose/2" do
    test "normalizes the input and counts the month's sessions, writing nothing",
         %{ctx: ctx} do
      input = %{
        @input
        | "start_time" => "09:30",
          "month" => "2026-08-17",
          "label" => " 早晨練習｜週一 基礎瑜伽 "
      }

      assert {:ok, %{student_id: nil, parsed: parsed}} = AddSlot.propose(input, ctx)

      assert parsed == %{
               "weekday" => 1,
               "start_time" => "09:30:00",
               "end_time" => "10:45:00",
               "label" => "早晨練習｜週一 基礎瑜伽",
               "default_style" => "基礎",
               "month" => "2026-08-01",
               "session_count" => 5
             }

      assert Studio.list_slots() == []
    end

    test "returns a message for the model when a field is missing or malformed",
         %{ctx: ctx} do
      for input <- [
            Map.delete(@input, "weekday"),
            %{@input | "weekday" => 0},
            %{@input | "weekday" => 8},
            %{@input | "weekday" => "1"},
            %{@input | "start_time" => "9am"},
            Map.delete(@input, "end_time"),
            %{@input | "end_time" => "09:30:00"},
            %{@input | "end_time" => "09:00:00"},
            %{@input | "label" => "  "},
            %{@input | "default_style" => 3},
            %{@input | "month" => "August"},
            Map.delete(@input, "month")
          ] do
        assert {:error, message} = AddSlot.propose(input, ctx)
        assert is_binary(message)
      end

      assert Studio.list_slots() == []
    end

    test "returns a message for the model when a slot already holds that weekday and time",
         %{ctx: ctx} do
      for active <- [true, false] do
        slot = slot_fixture(%{active: active})

        assert {:error, message} = AddSlot.propose(@input, ctx)
        assert is_binary(message)

        Repo.delete!(slot)
      end
    end

    test "allows the same time on another weekday", %{ctx: ctx} do
      slot_fixture(%{weekday: 2})

      assert {:ok, %{parsed: %{"weekday" => 1}}} = AddSlot.propose(@input, ctx)
    end
  end

  describe "apply/2" do
    test "creates an active slot and the month's sessions in its default style",
         %{ctx: ctx} do
      parsed = propose!(ctx)

      assert {:ok, {"Ganesha.Studio.Slot", slot_id}} = AddSlot.apply(parsed, "line:teacher")

      slot = Studio.get_slot!(slot_id)
      assert slot.weekday == 1
      assert slot.start_time == ~T[09:30:00]
      assert slot.end_time == ~T[10:45:00]
      assert slot.label == "早晨練習｜週一 基礎瑜伽"
      assert slot.default_style == "基礎"
      assert slot.active

      sessions = Studio.sessions_for_slot_in_month(slot, ~D[2026-08-01])
      assert length(sessions) == parsed["session_count"]

      assert Enum.map(sessions, & &1.date) ==
               [~D[2026-08-03], ~D[2026-08-10], ~D[2026-08-17], ~D[2026-08-24], ~D[2026-08-31]]

      assert Enum.all?(sessions, &(&1.style == "基礎"))
    end

    test "fails when a slot took that weekday and time after propose", %{ctx: ctx} do
      parsed = propose!(ctx)
      slot = slot_fixture(%{active: false})

      assert {:error, :slot_taken} = AddSlot.apply(parsed, "line:teacher")
      assert Enum.map(Studio.list_slots(), & &1.id) == [slot.id]
      assert Studio.sessions_in_month(~D[2026-08-01]) == []
    end
  end

  describe "describe/2" do
    test "shows the weekday, time, month, style and session count", %{ctx: ctx} do
      parsed = propose!(ctx)

      for {locale, weekday} <- [{"zh-TW", Fmt.weekday(1)}, {"en", "Mon"}] do
        %{
          title: title,
          lines: [weekday_line, time_line, month_line, style_line],
          changes: [{_label, nil, count}],
          web_path: path
        } = AddSlot.describe(parsed, locale)

        assert title =~ "早晨練習｜週一 基礎瑜伽"
        assert weekday_line =~ weekday
        assert time_line =~ Fmt.time_range(~T[09:30:00], ~T[10:45:00])
        assert month_line =~ Format.month_title(~D[2026-08-01], locale)
        assert style_line =~ "基礎"
        assert count =~ "5"
        assert path == "/class/2026/8"
      end
    end

    test "shows the stored values, not the current database", %{ctx: ctx} do
      parsed = %{
        propose!(ctx)
        | "month" => "2026-11-01",
          "session_count" => 7,
          "label" => "週末班"
      }

      %{title: title, lines: [_, _, month_line, _], changes: [{_, nil, count}], web_path: path} =
        AddSlot.describe(parsed, "zh-TW")

      assert title =~ "週末班"
      assert month_line =~ Format.month_title(~D[2026-11-01], "zh-TW")
      assert count =~ "7"
      assert path == "/class/2026/11"
    end
  end
end
