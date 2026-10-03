defmodule Ganesha.Assistant.Tasks.Enroll do
  @moduledoc """
  `enroll` (spec §3.1 #12): one Enrollment per Draft — a student in one Slot
  for a month's Sessions on a monthly Package, through
  `Ganesha.Enrolling.enroll_month/1`, as the web enroll screen does.
  "Several students" means several calls, one Draft each.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias GaneshaWeb.Fmt

  @apply_keys ~w(student_id slot_id package_id session_ids custom_amount note)

  @impl true
  def name, do: "enroll"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Enroll one student in one weekly Slot for a month on a monthly package (報名月課程). \
      This only proposes a Draft; the purchase and the bookings are created when the \
      teacher taps Confirm. For several students, call once per student. Use ids from the \
      studio snapshot. Omit session_ids to book every scheduled Session of that Slot in \
      the month, as the web screen does.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          slot_id: %{type: "integer"},
          month: %{type: "string", description: "The month as YYYY-MM, e.g. 2026-10"},
          package_id: %{type: "integer", description: "A monthly package"},
          session_ids: %{
            type: "array",
            items: %{type: "integer"},
            description: "Only these Sessions of the Slot in that month, if the teacher says so"
          },
          custom_amount: %{
            type: "integer",
            description: "NT$ owed instead of the package price, only if the teacher says so"
          },
          note: %{type: "string"}
        },
        required: ["student_id", "slot_id", "month", "package_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, student} <- fetch(:student, input["student_id"]),
         :ok <- check_active(student),
         {:ok, slot} <- fetch(:slot, input["slot_id"]),
         {:ok, month} <- parse_month(input["month"]),
         {:ok, package} <- fetch(:package, input["package_id"]),
         :ok <- check_monthly(package),
         :ok <- check_available(package, student),
         :ok <- check_amount(input["custom_amount"]),
         scheduled =
           slot |> Studio.sessions_for_slot_in_month(month) |> Enum.filter(&scheduled?/1),
         {:ok, sessions} <- pick_sessions(scheduled, input["session_ids"], slot, month),
         :ok <- check_not_booked(sessions, student) do
      parsed = %{
        "student_id" => student.id,
        "slot_id" => slot.id,
        "package_id" => package.id,
        "session_ids" => Enum.map(sessions, & &1.id),
        "custom_amount" => input["custom_amount"],
        "note" => input["note"],
        "student_name" => student.display_name,
        "slot_label" => Fmt.slot_title(slot.label),
        "slot_weekday" => slot.weekday,
        "slot_time" => Fmt.time_range(slot.start_time, slot.end_time),
        "month" => Calendar.strftime(month, "%Y-%m"),
        "session_dates" => Enum.map(sessions, &Date.to_iso8601(&1.date)),
        "package_name" => package.name,
        "price_per_class" => package.price_per_class,
        "price" => Catalog.price_for(package, length(sessions))
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <- load(:student, attrs["student_id"]),
         {:ok, slot} <- load(:slot, attrs["slot_id"]),
         {:ok, package} <- load(:package, attrs["package_id"]),
         {:ok, sessions} <- load_sessions(attrs["session_ids"]),
         :ok <- still_scheduled(sessions),
         :ok <- still_available(package, student),
         :ok <- same_price(package, length(sessions), parsed["price"]),
         {:ok, %{purchase: purchase}} <-
           Enrolling.enroll_month(%{
             student: student,
             slot: slot,
             package: package,
             sessions: sessions,
             custom_amount: attrs["custom_amount"],
             note: attrs["note"]
           }) do
      {:ok, {"Ganesha.Sales.Purchase", purchase.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    dates = Enum.flat_map(parsed["session_dates"] || [], &parse_date/1)
    month = parse_month_text(parsed["month"])

    %{
      title:
        Enum.join(
          [
            title(locale),
            parsed["student_name"],
            month_text(month, locale),
            weekday_text(parsed["slot_weekday"], locale),
            parsed["slot_label"]
          ]
          |> Enum.reject(&(&1 in [nil, ""])),
          " "
        ),
      lines:
        Enum.reject(
          [
            slot_line(parsed, locale),
            sessions_line(dates, locale),
            package_line(parsed, locale),
            note_line(parsed["note"], locale)
          ],
          &is_nil/1
        ),
      changes: [{owed_label(locale), nil, Format.money(parsed["custom_amount"] || parsed["price"])}],
      web_path: web_path(parsed["slot_id"], month)
    }
  end

  defp fetch(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, "no #{what} with id #{id}; use an id from the snapshot"}
      record -> {:ok, record}
    end
  end

  defp fetch(what, _id), do: {:error, "#{what}_id must be an integer id from the snapshot"}

  defp load(what, id) when is_integer(id) do
    case get(what, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp load(_what, _id), do: {:error, :not_found}

  defp get(:student, id), do: People.get_student(id)
  defp get(:slot, id), do: Studio.get_slot(id)
  defp get(:package, id), do: Catalog.get_package(id)
  defp get(:session, id), do: Studio.get_session(id)

  defp load_sessions(ids) when is_list(ids) and ids != [] do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, sessions} ->
      case load(:session, id) do
        {:ok, session} -> {:cont, {:ok, sessions ++ [session]}}
        error -> {:halt, error}
      end
    end)
  end

  defp load_sessions(_ids), do: {:error, :no_sessions}

  defp check_active(%{active: true}), do: :ok
  defp check_active(student), do: {:error, "#{student.display_name} is inactive"}

  defp parse_month(text) when is_binary(text) do
    case Date.from_iso8601(text <> "-01") do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "month must be YYYY-MM, e.g. 2026-10"}
    end
  end

  defp parse_month(_text), do: {:error, "month must be YYYY-MM, e.g. 2026-10"}

  defp check_monthly(%{kind: "monthly"}), do: :ok

  defp check_monthly(package),
    do: {:error, "#{package.name} is not a monthly package; use book_one_off for 單堂 or 體驗"}

  defp check_available(package, student) do
    if available?(package, student),
      do: :ok,
      else: {:error, "#{package.name} is closed to #{student.display_name}"}
  end

  defp still_available(package, student) do
    if available?(package, student), do: :ok, else: {:error, :package_unavailable}
  end

  defp available?(package, student),
    do: Catalog.package_available?(package, Sales.purchased_package_ids_for_student(student.id))

  defp same_price(package, count, price) do
    if Catalog.price_for(package, count) == price, do: :ok, else: {:error, :price_changed}
  end

  defp check_amount(nil), do: :ok
  defp check_amount(amount) when is_integer(amount) and amount >= 0, do: :ok

  defp check_amount(_amount),
    do: {:error, "custom_amount must be a whole NT$ amount of 0 or more"}

  defp scheduled?(session), do: session.state == "scheduled"

  defp still_scheduled(sessions) do
    if Enum.all?(sessions, &scheduled?/1), do: :ok, else: {:error, :session_cancelled}
  end

  defp pick_sessions([], _ids, slot, month),
    do:
      {:error,
       "slot #{slot.id} has no scheduled sessions in #{Calendar.strftime(month, "%Y-%m")}"}

  defp pick_sessions(scheduled, nil, _slot, _month), do: {:ok, scheduled}

  defp pick_sessions(scheduled, ids, slot, month) when is_list(ids) and ids != [] do
    case Enum.reject(ids, fn id -> Enum.any?(scheduled, &(&1.id == id)) end) do
      [] ->
        {:ok, Enum.filter(scheduled, &(&1.id in ids))}

      unknown ->
        {:error,
         "sessions #{Enum.join(unknown, ", ")} are not scheduled sessions of slot #{slot.id} " <>
           "in #{Calendar.strftime(month, "%Y-%m")}; its scheduled sessions are " <>
           Enum.map_join(scheduled, ", ", &"#{&1.id} (#{Date.to_iso8601(&1.date)})")}
    end
  end

  defp pick_sessions(_scheduled, _ids, _slot, _month),
    do: {:error, "session_ids must be a non-empty list of session ids, or omitted"}

  defp check_not_booked(sessions, student) do
    booked =
      Enum.filter(sessions, fn session ->
        session |> Roster.list_for_session() |> Enum.any?(&(&1.student_id == student.id))
      end)

    case booked do
      [] ->
        :ok

      booked ->
        {:error,
         "#{student.display_name} is already booked on " <>
           Enum.map_join(booked, ", ", &Date.to_iso8601(&1.date)) <>
           "; pass session_ids without those sessions, or ask the teacher"}
    end
  end

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> [date]
      {:error, _} -> []
    end
  end

  defp parse_date(_iso), do: []

  defp parse_month_text(text) when is_binary(text) do
    case Date.from_iso8601(text <> "-01") do
      {:ok, date} -> date
      {:error, _} -> nil
    end
  end

  defp parse_month_text(_text), do: nil

  defp title("en"), do: "Enroll"
  defp title(_locale), do: "報名"

  defp month_text(nil, _locale), do: nil
  defp month_text(month, "en"), do: Calendar.strftime(month, "%b")
  defp month_text(month, _locale), do: "#{month.month}月"

  defp weekday_text(day, "en") when day in 1..7,
    do: Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), day - 1)

  defp weekday_text(day, _locale) when day in 1..7, do: Fmt.weekday(day)
  defp weekday_text(_day, _locale), do: nil

  defp slot_line(parsed, "en"),
    do:
      "Class: #{weekday_text(parsed["slot_weekday"], "en")} #{parsed["slot_time"]} " <>
        "#{parsed["slot_label"]}"

  defp slot_line(parsed, _locale),
    do:
      "固定班：#{weekday_text(parsed["slot_weekday"], "zh-TW")} #{parsed["slot_time"]} " <>
        "#{parsed["slot_label"]}"

  defp sessions_line([], _locale), do: nil

  defp sessions_line(dates, "en"),
    do: "Sessions: #{Enum.map_join(dates, ", ", &Fmt.short_date/1)} (#{length(dates)})"

  defp sessions_line(dates, _locale),
    do: "課堂：#{Enum.map_join(dates, "、", &Fmt.short_date/1)}（#{length(dates)} 堂）"

  defp package_line(parsed, "en"),
    do:
      "Package: #{parsed["package_name"]} #{Format.money(parsed["price_per_class"])}/class, " <>
        "list #{Format.money(parsed["price"])}"

  defp package_line(parsed, _locale),
    do:
      "方案：#{parsed["package_name"]} #{Format.money(parsed["price_per_class"])}／堂，" <>
        "原價 #{Format.money(parsed["price"])}"

  defp note_line(note, _locale) when note in [nil, ""], do: nil
  defp note_line(note, "en"), do: "Note: #{note}"
  defp note_line(note, _locale), do: "備註：#{note}"

  defp owed_label("en"), do: "Owed"
  defp owed_label(_locale), do: "應付"

  defp web_path(slot_id, %Date{} = month) when is_integer(slot_id),
    do: "/enroll/#{slot_id}/#{month.year}/#{month.month}"

  defp web_path(_slot_id, _month), do: nil
end
