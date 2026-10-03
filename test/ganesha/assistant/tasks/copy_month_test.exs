defmodule Ganesha.Assistant.Tasks.CopyMonthTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Format
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
      assert parsed == %{"month" => "2026-09-01", "session_count" => 8}
      assert length(september()) == 1
    end

    test "returns a message for the model when nothing would be created", %{ctx: ctx} do
      assert {:error, message} = CopyMonth.propose(%{"month" => "2026-09-01"}, ctx)
      assert is_binary(message)

      slot = slot_fixture()
      {:ok, _} = Studio.generate_month(slot, ~D[2026-09-01])

      assert {:error, message} = CopyMonth.propose(%{"month" => "2026-09-01"}, ctx)
      assert is_binary(message)
    end

    test "returns a message for the model when the month is malformed", %{ctx: ctx} do
      slot_fixture()

      for input <- [%{}, %{"month" => "September"}, %{"month" => 9}] do
        assert {:error, message} = CopyMonth.propose(input, ctx)
        assert is_binary(message)
      end
    end
  end

  describe "apply/2" do
    test "creates the promised sessions for every active slot", %{ctx: ctx} do
      slot = slot_fixture()
      {:ok, _} = Studio.generate_month(slot, ~D[2026-08-01])
      parsed = propose!(ctx)

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

    test "fails when the month was already copied after propose", %{ctx: ctx} do
      slot_fixture()
      parsed = propose!(ctx)
      {:ok, 4} = Studio.copy_month(~D[2026-09-01])

      assert {:error, :schedule_changed} = CopyMonth.apply(parsed, "line:teacher")
      assert length(september()) == 4
    end
  end

  describe "describe/2" do
    test "shows the target month and the stored session count" do
      parsed = %{"month" => "2026-11-01", "session_count" => 9}

      for locale <- ["zh-TW", "en"] do
        %{title: title, lines: [], changes: [{_label, nil, count}], web_path: path} =
          CopyMonth.describe(parsed, locale)

        assert title =~ Format.month_title(~D[2026-11-01], locale)
        assert count =~ "9"
        assert path == "/class/2026/11"
      end
    end
  end
end
