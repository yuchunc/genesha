defmodule Ganesha.Assistant.Tasks.NextSessionTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Clock, Enrolling, People, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.NextSession

  # Studio.next_session/0 reads Clock.today(), so every date is relative to it.
  setup do
    today = Clock.today()
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
      Studio.create_session(%{slot_id: slot.id, date: Date.add(today, 2), style: "Hatha"})

    {:ok, student} = People.create_student(%{display_name: "Lulu"})

    {:ok, package} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} = Enrolling.add_one_off(session, student, package, [])

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: today},
      today: today,
      slot: slot,
      session: session
    }
  end

  defp session_on(slot, date) do
    {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: date, style: "Hatha"})
    session
  end

  test "answers with the nearest scheduled session and its roster", c do
    session_on(c.slot, Date.add(c.today, -1))
    session_on(c.slot, Date.add(c.today, 9))

    assert {:ok, %{data: data, card: {:session, payload}}} = NextSession.answer(%{}, c.ctx)

    assert data =~ ~r/Session #{c.session.id}\b/
    assert data =~ "Lulu"
    assert payload["title"] =~ Format.session_day(c.session.date, "zh-TW")
    assert payload["count"] == 1
    assert payload["cancelled"] == false
    assert payload["attendees"] == [%{"name" => "Lulu", "kind" => "drop_in", "no_show" => false}]
  end

  test "skips a cancelled session for the next scheduled one, even with nobody booked", c do
    later = session_on(c.slot, Date.add(c.today, 9))
    {:ok, _} = Studio.cancel_session(c.session, "颱風")

    assert {:ok, %{data: data, card: {:session, payload}}} = NextSession.answer(%{}, c.ctx)

    assert data =~ ~r/Session #{later.id}\b/
    refute data =~ "Lulu"
    assert payload["count"] == 0
    assert payload["attendees"] == []
  end

  test "errors when nothing is scheduled from today onward", c do
    session_on(c.slot, Date.add(c.today, -1))
    {:ok, _} = Studio.cancel_session(c.session, "颱風")

    assert {:error, message} = NextSession.answer(%{}, c.ctx)
    assert is_binary(message)
  end
end
