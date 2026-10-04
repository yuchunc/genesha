defmodule Ganesha.Assistant.Tasks.SessionRosterTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Studio}
  alias Ganesha.Assistant.Tasks.SessionRoster

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

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

    {:ok, package} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      slot: slot,
      session: session,
      package: package
    }
  end

  defp book(session, package, name) do
    {:ok, student} = People.create_student(%{display_name: name})
    {:ok, %{attendance: attendance}} = Enrolling.add_one_off(session, student, package, [])
    attendance
  end

  test "lists everyone booked with their kind and flags a no-show", c do
    lulu = book(c.session, c.package, "Lulu")
    amy = book(c.session, c.package, "Amy")
    {:ok, _} = Roster.mark_no_show(amy)

    assert {:ok, %{data: data} = answer} =
             SessionRoster.answer(%{"session_id" => c.session.id}, c.ctx)

    refute Map.has_key?(answer, :card)
    assert data =~ ~r/Session #{c.session.id}\b/
    assert data =~ "(Hatha)"
    assert data =~ "2 booked"
    refute data =~ "cancelled"
    assert data =~ "Lulu (attendance #{lulu.id}, drop_in, expected)"
    assert data =~ "Amy (attendance #{amy.id}, drop_in, no_show)"
  end

  test "flags a cancelled session", c do
    book(c.session, c.package, "Lulu")
    {:ok, _} = Studio.cancel_session(c.session, "颱風")

    assert {:ok, %{data: data}} =
             SessionRoster.answer(%{"session_id" => c.session.id}, c.ctx)

    assert data =~ "1 booked (cancelled)"
  end

  test "answers an empty roster", c do
    assert {:ok, %{data: data}} =
             SessionRoster.answer(%{"session_id" => c.session.id}, c.ctx)

    assert data =~ ~r/Session #{c.session.id}\b/
    assert data =~ "0 booked"
    refute data =~ "attendance"
  end

  test "rejects an unknown, non-integer or missing session_id", c do
    assert {:error, _} = SessionRoster.answer(%{"session_id" => c.session.id + 1000}, c.ctx)
    assert {:error, _} = SessionRoster.answer(%{"session_id" => "#{c.session.id}"}, c.ctx)
    assert {:error, _} = SessionRoster.answer(%{}, c.ctx)
  end
end
