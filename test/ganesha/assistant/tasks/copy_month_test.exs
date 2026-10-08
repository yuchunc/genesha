defmodule Ganesha.Assistant.Tasks.CopyMonthTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Tasks.CopyMonth

  # September 2026 has four Mondays (7, 14, 21, 28) and five Wednesdays (2, 9, 16, 23, 30).
  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  defp slot_fixture(attrs \\ %{}) do
    {:ok, slot} =
      Studio.create_slot(
        Map.merge(
          %{
            weekday: 1,
            start_time: ~T[09:30:00],
            end_time: ~T[10:45:00],
            default_style: "基礎",
            label: "早晨練習｜週一 基礎瑜伽"
          },
          attrs
        )
      )

    slot
  end

  defp propose!(ctx, month \\ "2026-09-01") do
    {:ok, %{parsed: parsed}} = CopyMonth.propose(%{"month" => month}, ctx)
    parsed
  end

  defp september, do: Studio.sessions_in_month(~D[2026-09-01])

  describe "propose/2" do
    test "counts the sessions every active slot still lacks, writing nothing", %{ctx: ctx} do
      monday = slot_fixture()
      {:ok, _} = Studio.generate_month(monday, ~D[2026-08-01])
      slot_fixture(%{weekday: 3, start_time: ~T[19:00:00], end_time: ~T[20:00:00]})
      slot_fixture(%{weekday: 5, active: false})
      {:ok, _} = Studio.create_session(%{slot_id: monday.id, date: ~D[2026-09-14], style: "流動"})

      assert {:ok, %{student_id: nil, parsed: parsed}} =
               CopyMonth.propose(%{"month" => "2026-09-20"}, ctx)

      # 3 Mondays (9/14 exists) + 5 Wednesdays; the inactive Friday slot is skipped.
      assert parsed["month"] == "2026-09-01"
      assert parsed["session_count"] == 8
      assert length(september()) == 1
    end

    test "returns distinct messages for no active slots and an already full month",
         %{ctx: ctx} do
      slot = slot_fixture(%{active: false})
      {:ok, _} = Studio.generate_month(slot, ~D[2026-09-01])
      assert {:error, no_slots} = CopyMonth.propose(%{"month" => "2026-09-01"}, ctx)
      assert is_binary(no_slots)

      {:ok, _} = Studio.update_slot(slot, %{active: true})
      assert {:error, nothing_new} = CopyMonth.propose(%{"month" => "2026-09-01"}, ctx)
      assert is_binary(nothing_new)

      assert no_slots != nothing_new
    end

    test "returns a message for the model when the month is malformed", %{ctx: ctx} do
      slot_fixture()

      for input <- [%{}, %{"month" => "September"}, %{"month" => 9}] do
        assert {:error, message} = CopyMonth.propose(input, ctx)
        assert is_binary(message)
      end
    end

    test "slot_ids limits the copy to the classes she named", %{ctx: ctx} do
      monday = slot_fixture()
      wednesday = slot_fixture(%{weekday: 3, start_time: ~T[19:00:00], end_time: ~T[20:00:00]})

      assert {:ok, %{parsed: parsed}} =
               CopyMonth.propose(%{"month" => "2026-09-01", "slot_ids" => [wednesday.id]}, ctx)

      assert parsed["slot_ids"] == [wednesday.id]
      assert parsed["session_count"] == 5
      assert Enum.all?(parsed["new_sessions"], fn [slot_id, _date] -> slot_id == wednesday.id end)
      refute Enum.any?(parsed["new_sessions"], fn [slot_id, _date] -> slot_id == monday.id end)
    end

    test "slot_ids naming an inactive, unknown or malformed slot is refused", %{ctx: ctx} do
      slot_fixture()
      inactive = slot_fixture(%{weekday: 5, active: false})

      for ids <- [[inactive.id], [999_999], [], ["1"], "1"] do
        assert {:error, message} =
                 CopyMonth.propose(%{"month" => "2026-09-01", "slot_ids" => ids}, ctx)

        assert is_binary(message)
      end
    end
  end

  describe "apply/2" do
    test "creates the promised sessions for every active slot", %{ctx: ctx} do
      slot = slot_fixture()
      {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])
      # The Draft stores parsed as JSON; apply must accept it after the round trip.
      parsed = ctx |> propose!() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, {nil, nil}} = CopyMonth.apply(parsed, "line:teacher")

      assert slot |> Studio.sessions_for_slot_in_month(~D[2026-09-01]) |> Enum.map(& &1.date) ==
               [~D[2026-09-07], ~D[2026-09-14], ~D[2026-09-21], ~D[2026-09-28]]

      assert length(september()) == parsed["session_count"]
    end

    test "fails when the schedule changed after propose, writing nothing", %{ctx: ctx} do
      slot_fixture()
      parsed = propose!(ctx)
      slot_fixture(%{weekday: 3})

      assert {:error, :schedule_changed} = CopyMonth.apply(parsed, "line:teacher")
      assert september() == []
    end

    test "fails when other sessions would be created, even at the same count", %{ctx: ctx} do
      monday = slot_fixture()
      parsed = propose!(ctx)
      {:ok, _} = Studio.update_slot(monday, %{active: false})
      # September 2026 also has four Thursdays (3, 10, 17, 24).
      slot_fixture(%{weekday: 4})

      assert {:error, :schedule_changed} = CopyMonth.apply(parsed, "line:teacher")
      assert september() == []
    end

    test "with slot_ids, creates only those classes' sessions", %{ctx: ctx} do
      monday = slot_fixture()
      wednesday = slot_fixture(%{weekday: 3, start_time: ~T[19:00:00], end_time: ~T[20:00:00]})

      {:ok, %{parsed: parsed}} =
        CopyMonth.propose(%{"month" => "2026-09-01", "slot_ids" => [monday.id]}, ctx)

      parsed = parsed |> Jason.encode!() |> Jason.decode!()
      assert {:ok, {nil, nil}} = CopyMonth.apply(parsed, "line:teacher")

      assert length(Studio.sessions_for_slot_in_month(monday, ~D[2026-09-01])) == 4
      assert Studio.sessions_for_slot_in_month(wednesday, ~D[2026-09-01]) == []
    end

    test "fails when a class she picked was deactivated after propose", %{ctx: ctx} do
      monday = slot_fixture()

      {:ok, %{parsed: parsed}} =
        CopyMonth.propose(%{"month" => "2026-09-01", "slot_ids" => [monday.id]}, ctx)

      {:ok, _} = Studio.update_slot(monday, %{active: false})

      assert {:error, :schedule_changed} = CopyMonth.apply(parsed, "line:teacher")
      assert september() == []
    end

    test "fails when the month was already copied after propose", %{ctx: ctx} do
      slot_fixture()
      parsed = propose!(ctx)
      {:ok, 4} = Studio.copy_month(~D[2026-09-01])

      assert {:error, :schedule_changed} = CopyMonth.apply(parsed, "line:teacher")
      assert length(september()) == 4
    end
  end

  describe "summary/2" do
    test "summary names the month and how many sessions it adds" do
      parsed = %{"month" => "2026-11-01", "session_count" => 9}
      assert CopyMonth.summary(parsed, "zh-TW") =~ "11月"
      assert CopyMonth.summary(parsed, "en") =~ "November"
      for locale <- ["zh-TW", "en"], do: assert(CopyMonth.summary(parsed, locale) =~ "9")
    end

    test "summary names the classes when only some are copied" do
      parsed = %{
        "month" => "2026-11-01",
        "session_count" => 5,
        "slots" => [%{"weekday" => 1, "time" => "09:30–10:45", "title" => "早晨練習"}]
      }

      assert CopyMonth.summary(parsed, "zh-TW") =~ "週一 09:30–10:45 早晨練習"
      assert CopyMonth.summary(parsed, "en") =~ "09:30–10:45 早晨練習"
    end
  end
end
