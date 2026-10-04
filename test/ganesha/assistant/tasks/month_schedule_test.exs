defmodule Ganesha.Assistant.Tasks.MonthScheduleTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.MonthSchedule

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

    on = fn date ->
      {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: date, style: "Hatha"})
      session
    end

    september = on.(~D[2026-09-30])
    oct7 = on.(~D[2026-10-07])
    oct14 = on.(~D[2026-10-14])
    november = on.(~D[2026-11-04])

    {:ok, workshop} =
      Studio.create_session(%{
        date: ~D[2026-10-24],
        style: "Yin",
        label: "工作坊",
        start_time: ~T[14:00:00],
        end_time: ~T[16:00:00]
      })

    {:ok, package} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    for {session, name} <- [{oct7, "Lulu"}, {oct7, "Amy"}, {november, "Bea"}] do
      {:ok, student} = People.create_student(%{display_name: name})
      {:ok, _} = Enrolling.add_one_off(session, student, package, [])
    end

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      september: september,
      oct7: oct7,
      oct14: oct14,
      workshop: workshop,
      november: november
    }
  end

  defp names_session?(data, session), do: data =~ ~r/Session #{session.id}\b/

  # One session's entry in the data: "Session <id>: <day> <label> <time range>, <n> booked".
  defp entry?(data, session, label, time, count) do
    head =
      Regex.escape(
        "Session #{session.id}: #{Format.session_day(session.date, "zh-TW")} #{label} #{time}"
      )

    data =~ ~r/#{head}[^;]*, #{count} booked/
  end

  test "defaults to today's month and counts who is booked in each session", c do
    assert {:ok, %{data: data} = answer} = MonthSchedule.answer(%{}, c.ctx)
    refute Map.has_key?(answer, :card)

    assert String.starts_with?(
             data,
             Format.month_title(~D[2026-10-01], "zh-TW") <> ": 3 session(s)"
           )

    assert entry?(data, c.oct7, "基礎", "19:00", 2)
    assert entry?(data, c.oct14, "基礎", "19:00", 0)
    assert entry?(data, c.workshop, "工作坊", "14:00", 0)
    refute names_session?(data, c.september)
    refute names_session?(data, c.november)
  end

  test "a date inside another month lands on that month", c do
    assert {:ok, %{data: data}} = MonthSchedule.answer(%{"month" => "2026-11-20"}, c.ctx)

    assert String.starts_with?(
             data,
             Format.month_title(~D[2026-11-01], "zh-TW") <> ": 1 session(s)"
           )

    assert entry?(data, c.november, "基礎", "19:00", 1)
    refute names_session?(data, c.oct7)
  end

  test "flags a cancelled session in the data", c do
    {:ok, _} = Studio.cancel_session(c.oct14, "颱風")

    assert {:ok, %{data: data}} = MonthSchedule.answer(%{"month" => "2026-10-01"}, c.ctx)

    assert data =~ ~r/Session #{c.oct14.id}\b[^;]*cancelled/
    refute data =~ ~r/Session #{c.oct7.id}\b[^;]*cancelled/
  end

  test "answers a month with no sessions", c do
    assert {:ok, %{data: data}} = MonthSchedule.answer(%{"month" => "2026-12-01"}, c.ctx)

    assert data == Format.month_title(~D[2026-12-01], "zh-TW") <> ": 0 session(s)"
  end

  test "rejects a month that is not an ISO 8601 date", c do
    assert {:error, _} = MonthSchedule.answer(%{"month" => "next month"}, c.ctx)
    assert {:error, _} = MonthSchedule.answer(%{"month" => 202_611}, c.ctx)
  end
end
