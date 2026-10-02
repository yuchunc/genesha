defmodule Ganesha.Assistant.Snapshot do
  @moduledoc """
  The studio snapshot sent with every Teacher chat and Group chat message
  (spec §2 rule 4, ADR 0002): Slots, Packages, the scheduled Sessions around
  today with headcounts, and every student with nicknames and what they owe —
  each with the id the tasks take. Model-facing, so labels are English and
  ledger data is shown as stored.
  """

  alias Ganesha.{Catalog, People, Repo, Reporting, Roster, Studio}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @days_back 7
  @days_ahead 28
  @weekdays ~w(Mon Tue Wed Thu Fri Sat Sun)

  @spec build(Date.t()) :: String.t()
  def build(%Date{} = today) do
    from = Date.add(today, -@days_back)
    to = Date.add(today, @days_ahead)

    Enum.join(
      [
        "Today: #{Date.to_iso8601(today)} (#{weekday(Date.day_of_week(today))})",
        section("Slots (weekly classes)", Enum.map(Studio.list_slots(), &slot_line/1)),
        section("Packages", Enum.map(Catalog.list_packages(), &package_line/1)),
        section(
          "Scheduled sessions #{Date.to_iso8601(from)} to #{Date.to_iso8601(to)}",
          session_lines(from, to)
        ),
        section("Students", student_lines())
      ],
      "\n\n"
    )
  end

  defp section(title, []), do: "#{title}:\n(none)"
  defp section(title, lines), do: Enum.join(["#{title}:" | lines], "\n")

  defp slot_line(slot) do
    "- slot #{slot.id}: #{weekday(slot.weekday)} " <>
      "#{Fmt.time_range(slot.start_time, slot.end_time)} #{Fmt.slot_title(slot.label)} " <>
      "(#{slot.default_style})" <>
      if(slot.active, do: "", else: " [inactive]")
  end

  defp package_line(package) do
    "- package #{package.id}: #{package.name} (#{package.kind}, " <>
      "#{Format.money(package.price_per_class)}/class, #{package.included_makeups} makeups)" <>
      if(package.active, do: "", else: " [closed to new students]")
  end

  defp session_lines(from, to) do
    sessions = Studio.sessions_between(from, to)
    counts = sessions |> Enum.map(& &1.id) |> Roster.count_by_session()

    Enum.map(sessions, fn session ->
      "- session #{session.id}: #{Date.to_iso8601(session.date)} " <>
        "#{weekday(Date.day_of_week(session.date))} #{Fmt.session_time_range(session)} " <>
        "#{Fmt.session_label(session)} #{session.style} — #{Map.get(counts, session.id, 0)} booked"
    end)
  end

  defp student_lines do
    owed = Reporting.outstanding_map()

    People.list_students()
    |> Repo.preload(:aliases)
    |> Enum.map(fn student ->
      "- student #{student.id}: #{student.display_name}" <>
        aliases(student.aliases) <>
        owes(Map.get(owed, student.id, 0)) <>
        if(student.active, do: "", else: " [inactive]")
    end)
  end

  defp aliases([]), do: ""
  defp aliases(aliases), do: " (aka #{Enum.map_join(aliases, ", ", & &1.alias)})"

  defp owes(amount) when amount > 0, do: " — owes #{Format.money(amount)}"
  defp owes(_amount), do: ""

  defp weekday(day_of_week), do: Enum.at(@weekdays, day_of_week - 1)
end
