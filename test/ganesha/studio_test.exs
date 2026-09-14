defmodule Ganesha.StudioTest do
  use Ganesha.DataCase
  alias Ganesha.Studio

  defp monday_slot do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    slot
  end

  test "generate_month/2 creates one session per matching weekday" do
    slot = monday_slot()
    # August 2026 Mondays: 3, 10, 17, 24, 31.
    assert {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])

    assert Enum.map(sessions, & &1.date) == [
             ~D[2026-08-03],
             ~D[2026-08-10],
             ~D[2026-08-17],
             ~D[2026-08-24],
             ~D[2026-08-31]
           ]

    assert Enum.all?(sessions, &(&1.style == "基礎"))
    assert Enum.all?(sessions, &(&1.state == "scheduled"))
  end

  test "generate_month/2 is idempotent and preserves a style override" do
    slot = monday_slot()
    {:ok, [first | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, _} = Studio.set_style(first, "流動")

    {:ok, again} = Studio.generate_month(slot, ~D[2026-08-01])

    assert length(again) == 5
    assert Studio.get_session!(first.id).style == "流動"
  end

  test "generate_month/2 is idempotent and preserves cancellation details" do
    slot = monday_slot()
    {:ok, [first | _]} = Studio.generate_month(slot, ~D[2026-08-01])
    {:ok, _} = Studio.cancel_session(first, "颱風假")

    {:ok, again} = Studio.generate_month(slot, ~D[2026-08-01])

    assert length(again) == 5

    first = Studio.get_session!(first.id)
    assert first.state == "cancelled"
    assert first.cancel_reason == "颱風假"
  end

  test "the same slot and date cannot be created twice" do
    slot = monday_slot()
    {:ok, _} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-08-03], style: "基礎"})

    assert {:error, cs} =
             Studio.create_session(%{slot_id: slot.id, date: ~D[2026-08-03], style: "基礎"})

    assert "has already been taken" in errors_on(cs).slot_id
  end

  test "the same weekday and start time cannot be created twice" do
    _slot = monday_slot()

    assert {:error, cs} =
             Studio.create_slot(%{
               weekday: 1,
               start_time: ~T[09:30:00],
               end_time: ~T[12:00:00],
               default_style: "流動",
               label: "duplicate"
             })

    assert "has already been taken" in errors_on(cs).weekday
  end

  test "set_style/2 changes one date only" do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:ok, updated} = Studio.set_style(session, "流動")
    assert updated.style == "流動"

    others = slot |> Studio.sessions_for_slot_in_month(~D[2026-08-01]) |> Enum.drop(1)
    assert Enum.all?(others, &(&1.style == "基礎"))
  end

  test "cancel_session/2 records the state and reason" do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:ok, cancelled} = Studio.cancel_session(session, "颱風假")
    assert cancelled.state == "cancelled"
    assert cancelled.cancel_reason == "颱風假"
  end

  test "cancel_session/2 requires a reason" do
    slot = monday_slot()
    {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])

    assert {:error, cs} = Studio.cancel_session(session, "")
    assert "can't be blank" in errors_on(cs).cancel_reason
  end

  test "next_session/0 breaks same-date ties by slot start time" do
    morning = monday_slot()

    {:ok, afternoon} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[15:30:00],
        end_time: ~T[16:45:00],
        default_style: "基礎",
        label: "午後練習｜週一 基礎瑜伽"
      })

    today = Ganesha.Clock.today()

    {:ok, _later_in_day} =
      Studio.create_session(%{slot_id: afternoon.id, date: today, style: "基礎"})

    {:ok, earlier_in_day} =
      Studio.create_session(%{slot_id: morning.id, date: today, style: "基礎"})

    next = Studio.next_session()
    assert next.id == earlier_in_day.id
    assert next.slot.start_time == ~T[09:30:00]
  end

  test "next_session/0 skips cancelled sessions" do
    slot = monday_slot()
    today = Ganesha.Clock.today()

    {:ok, soon} = Studio.create_session(%{slot_id: slot.id, date: today, style: "基礎"})

    {:ok, later} =
      Studio.create_session(%{slot_id: slot.id, date: Date.add(today, 7), style: "基礎"})

    assert Studio.next_session().id == soon.id

    {:ok, _} = Studio.cancel_session(soon, "颱風假")
    assert Studio.next_session().id == later.id
  end

  test "next_session/0 includes a standalone session and orders it against slot sessions" do
    slot = monday_slot()
    today = Ganesha.Clock.today()

    {:ok, _later} =
      Studio.create_session(%{slot_id: slot.id, date: Date.add(today, 7), style: "基礎"})

    {:ok, standalone} =
      Studio.create_session(%{
        date: today,
        start_time: ~T[07:00:00],
        end_time: ~T[08:00:00],
        label: "體驗課",
        style: "流動",
        state: "scheduled"
      })

    next = Studio.next_session()
    assert next.id == standalone.id
    assert next.slot == nil
  end

  describe "standalone sessions" do
    test "creates a session with no slot when label, start_time and end_time are given" do
      assert {:ok, session} =
               Studio.create_session(%{
                 date: ~D[2026-08-10],
                 start_time: ~T[19:00:00],
                 end_time: ~T[20:00:00],
                 label: "期間限定：中秋瑜伽",
                 style: "流動",
                 state: "scheduled"
               })

      assert session.slot_id == nil
      assert session.label == "期間限定：中秋瑜伽"
      assert session.start_time == ~T[19:00:00]
    end

    test "rejects a session with neither a slot nor standalone fields" do
      assert {:error, changeset} =
               Studio.create_session(%{date: ~D[2026-08-10], style: "流動", state: "scheduled"})

      assert "單次的課需要日期、時間與名稱" in errors_on(changeset).label
    end

    test "rejects a session with both a slot and standalone fields" do
      slot = monday_slot()

      assert {:error, changeset} =
               Studio.create_session(%{
                 slot_id: slot.id,
                 date: ~D[2026-08-10],
                 start_time: ~T[19:00:00],
                 end_time: ~T[20:00:00],
                 label: "多餘的名稱",
                 style: "流動",
                 state: "scheduled"
               })

      assert "固定班次的課不需要另外填寫名稱與時間" in errors_on(changeset).slot_id
    end
  end

  describe "sessions_in_month/1" do
    test "returns recurring and standalone sessions together, slot preloaded" do
      slot = monday_slot()
      {:ok, [recurring | _]} = Studio.generate_month(slot, ~D[2026-08-01])

      {:ok, standalone} =
        Studio.create_session(%{
          date: ~D[2026-08-15],
          start_time: ~T[19:00:00],
          end_time: ~T[20:00:00],
          label: "體驗課",
          style: "流動",
          state: "scheduled"
        })

      sessions = Studio.sessions_in_month(~D[2026-08-01])

      assert Enum.find(sessions, &(&1.id == recurring.id)).slot.id == slot.id
      assert Enum.find(sessions, &(&1.id == standalone.id)).slot == nil
    end

    test "excludes sessions outside the month" do
      slot = monday_slot()
      Studio.generate_month(slot, ~D[2026-08-01])
      Studio.generate_month(slot, ~D[2026-09-01])

      assert Enum.all?(Studio.sessions_in_month(~D[2026-08-01]), &(&1.date.month == 8))
    end
  end

  describe "copy_month/1" do
    test "generates every active slot's sessions and skips inactive ones" do
      active = monday_slot()

      {:ok, inactive} =
        Studio.create_slot(%{
          weekday: 5,
          start_time: ~T[18:00:00],
          end_time: ~T[19:00:00],
          default_style: "流動",
          label: "週五",
          active: false
        })

      assert {:ok, 5} = Studio.copy_month(~D[2026-08-01])
      assert length(Studio.sessions_for_slot_in_month(active, ~D[2026-08-01])) == 5
      assert Studio.sessions_for_slot_in_month(inactive, ~D[2026-08-01]) == []
    end

    test "is idempotent" do
      monday_slot()
      assert {:ok, 5} = Studio.copy_month(~D[2026-08-01])
      assert {:ok, 0} = Studio.copy_month(~D[2026-08-01])
    end
  end

  test "sessions_between/2 returns scheduled sessions within an inclusive date range" do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        default_style: "Hatha",
        label: "一 早晨"
      })

    {:ok, in_range} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-09-14], style: "Hatha"})

    {:ok, _out_of_range} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-09-21], style: "Hatha"})

    result = Studio.sessions_between(~D[2026-09-12], ~D[2026-09-18])
    assert [%{id: id}] = result
    assert id == in_range.id
  end
end
