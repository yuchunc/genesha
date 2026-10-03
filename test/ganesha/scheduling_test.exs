defmodule Ganesha.SchedulingTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, People, Repo, Roster, Sales, Scheduling, Studio}

  @monday %{
    weekday: 1,
    start_time: ~T[09:30:00],
    end_time: ~T[10:45:00],
    default_style: "基礎",
    label: "早晨練習｜週一 基礎瑜伽"
  }

  defp seat_monthly(slot, session, name) do
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, package} =
      Catalog.create_package(%{name: "月課程 #{name}", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: package.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)
    student
  end

  # Makes every INSERT into `table` fail at the database, to prove a step
  # failing midway leaves no partial change behind. The trigger lives on the
  # test's sandboxed connection and is rolled back with it.
  defp fail_inserts_into(table) do
    Repo.query!("""
    CREATE TEMP TRIGGER fail_#{table}_insert BEFORE INSERT ON #{table}
    BEGIN SELECT RAISE(ABORT, 'injected failure'); END
    """)
  end

  describe "cancel_session/2" do
    test "cancels the session and issues a credit to each seated student" do
      {:ok, slot} = Studio.create_slot(@monday)
      {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
      lanzi = seat_monthly(slot, session, "蘭子")
      dandan = seat_monthly(slot, session, "丹丹")

      assert {:ok, %{session: cancelled, credits: credits}} =
               Scheduling.cancel_session(session, "颱風假")

      assert cancelled.state == "cancelled"
      assert cancelled.cancel_reason == "颱風假"
      assert Enum.sort(Enum.map(credits, & &1.student_id)) == Enum.sort([lanzi.id, dandan.id])
      assert Enum.all?(credits, &(&1.origin_session_id == session.id))
      assert Studio.get_session!(session.id).state == "cancelled"
    end

    test "without a reason returns the changeset and changes nothing" do
      {:ok, slot} = Studio.create_slot(@monday)
      {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
      lanzi = seat_monthly(slot, session, "蘭子")

      assert {:error, %Ecto.Changeset{} = changeset} = Scheduling.cancel_session(session, "")
      assert %{cancel_reason: [_]} = errors_on(changeset)
      assert Studio.get_session!(session.id).state == "scheduled"
      assert Roster.available_credits(lanzi.id, ~D[2026-12-01]) == []
    end

    test "when issuing credits fails, the session stays scheduled" do
      {:ok, slot} = Studio.create_slot(@monday)
      {:ok, [session | _]} = Studio.generate_month(slot, ~D[2026-08-01])
      seat_monthly(slot, session, "蘭子")
      fail_inserts_into("credits")

      assert_raise Exqlite.Error, fn -> Scheduling.cancel_session(session, "颱風假") end

      reloaded = Studio.get_session!(session.id)
      assert reloaded.state == "scheduled"
      assert reloaded.cancel_reason == nil
    end
  end

  describe "add_weekly_class/2" do
    test "creates the slot and its sessions for the month" do
      assert {:ok, %{slot: slot, sessions: sessions}} =
               Scheduling.add_weekly_class(@monday, ~D[2026-08-01])

      # August 2026 Mondays.
      assert Enum.map(sessions, & &1.date) ==
               [~D[2026-08-03], ~D[2026-08-10], ~D[2026-08-17], ~D[2026-08-24], ~D[2026-08-31]]

      assert Enum.all?(sessions, &(&1.slot_id == slot.id and &1.style == "基礎"))
      assert Studio.list_active_slots() == [slot]
    end

    test "a weekday and time already taken returns the changeset and creates nothing" do
      {:ok, existing} = Studio.create_slot(@monday)

      assert {:error, %Ecto.Changeset{}} =
               Scheduling.add_weekly_class(
                 %{@monday | end_time: ~T[11:00:00], label: "另一堂課"},
                 ~D[2026-08-01]
               )

      assert Studio.list_slots() == [existing]
      assert Studio.sessions_in_month(~D[2026-08-01]) == []
    end

    test "when generating the month's sessions fails, no slot is left behind" do
      fail_inserts_into("sessions")

      assert_raise Exqlite.Error, fn -> Scheduling.add_weekly_class(@monday, ~D[2026-08-01]) end

      assert Studio.list_slots() == []
    end
  end
end
