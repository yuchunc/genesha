defmodule Ganesha.Assistant.Tasks.SetNoShowTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, Enrolling, People, Roster, Studio}
  alias Ganesha.Assistant.Tasks.SetNoShow

  setup do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 3,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, _} = Enrolling.add_one_off(session, student, package, [])
    attendance = hd(Roster.list_for_session(session))

    %{ctx: %{locale: "zh-TW", today: ~D[2026-10-02]}, attendance: attendance, session: session}
  end

  test "marks no-show and can undo", c do
    assert {:ok, %{parsed: parsed}} =
             SetNoShow.propose(
               %{"attendance_id" => c.attendance.id, "state" => "no_show"},
               c.ctx
             )

    assert {:ok, _} = SetNoShow.apply(parsed, "line:teacher")
    assert Roster.get_attendance!(c.attendance.id).state == "no_show"

    assert {:ok, %{parsed: undo}} =
             SetNoShow.propose(
               %{"attendance_id" => c.attendance.id, "state" => "expected"},
               c.ctx
             )

    assert {:ok, _} = SetNoShow.apply(undo, "line:teacher")
    assert Roster.get_attendance!(c.attendance.id).state == "expected"
  end

  test "propose rejects when already in that state", c do
    assert {:error, _} =
             SetNoShow.propose(
               %{"attendance_id" => c.attendance.id, "state" => "expected"},
               c.ctx
             )
  end

  test "apply fails if attendance changed after propose", c do
    {:ok, %{parsed: parsed}} =
      SetNoShow.propose(%{"attendance_id" => c.attendance.id, "state" => "no_show"}, c.ctx)

    {:ok, _} = Roster.mark_no_show(c.attendance)
    assert {:error, :attendance_changed} = SetNoShow.apply(parsed, "line:teacher")
  end
end
