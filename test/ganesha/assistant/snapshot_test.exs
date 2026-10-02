defmodule Ganesha.Assistant.SnapshotTest do
  use Ganesha.DataCase

  alias Ganesha.{Catalog, Enrolling, People, Studio}
  alias Ganesha.Assistant.Snapshot

  test "lists slots, packages, nearby sessions with headcounts, and students with nicknames and debts" do
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

    {:ok, far} = Studio.create_session(%{slot_id: slot.id, date: ~D[2026-11-25], style: "Hatha"})
    {:ok, drop_in} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})
    {:ok, _} = People.add_alias(lulu, "露露")
    {:ok, _} = Enrolling.add_one_off(session, lulu, drop_in, [])

    snapshot = Snapshot.build(~D[2026-10-02])

    assert snapshot =~ "Today: 2026-10-02 (Fri)"
    assert snapshot =~ "- slot #{slot.id}: Wed 19:00–20:15 基礎 (Hatha)"
    assert snapshot =~ "- package #{drop_in.id}: 單堂 (drop_in, NT$400/class, 0 makeups)"
    assert snapshot =~ "- session #{session.id}: 2026-10-07 Wed 19:00–20:15 基礎 Hatha — 1 booked"
    refute snapshot =~ "- session #{far.id}:"
    assert snapshot =~ "- student #{lulu.id}: Lulu (aka 露露) — owes NT$400"
  end

  test "says when a section is empty" do
    assert Snapshot.build(~D[2026-10-02]) =~ "Students:\n(none)"
  end
end
