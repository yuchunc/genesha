defmodule Ganesha.Assistant.Tasks.Enroll do
  @moduledoc """
  `enroll` (spec §3.1 #12): one Enrollment per Draft — a student in one Slot
  for a month's Sessions on a monthly Package, through
  `Ganesha.Enrolling.enroll_month/1`, as the web enroll screen does.
  "Several students" means several calls, one Draft each.

  With a `signup_request_id` (spec 2026-10-07 §2) the Draft also settles that
  sign-up request on confirm, and may add the newcomer as a new student with
  the request's LINE user id, or link that id to the existing student.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Summary
  alias GaneshaWeb.Fmt

  @apply_keys ~w(student_id slot_id package_id session_ids custom_amount note
                 signup_request_id new_student link_line_user_id)

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
      the month, as the web screen does. For a sign-up request, pass its number as \
      signup_request_id: confirming then settles the request too. Give student_id, or, \
      for a sign-up request from someone not in the snapshot, new_student_name instead.\
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
          note: %{type: "string"},
          signup_request_id: %{
            type: "integer",
            description: "N from a [報名申請 #N] / [Sign-up request #N] message"
          },
          new_student_name: %{
            type: "string",
            description:
              "Only with signup_request_id, when no snapshot student fits: the new " <>
                "student's name, created with the request's LINE user id on Confirm"
          }
        },
        required: ["slot_id", "month", "package_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, request} <- fetch_request(input["signup_request_id"]),
         {:ok, who} <- resolve_student(input, request),
         :ok <- check_active(who),
         {:ok, slot} <- fetch(:slot, input["slot_id"]),
         {:ok, month} <- parse_month(input["month"]),
         {:ok, package} <- fetch(:package, input["package_id"]),
         :ok <- check_monthly(package),
         :ok <- check_available(package, who),
         :ok <- check_amount(input["custom_amount"]),
         scheduled =
           slot |> Studio.sessions_for_slot_in_month(month) |> Enum.filter(&scheduled?/1),
         {:ok, sessions} <- pick_sessions(scheduled, input["session_ids"], slot, month),
         :ok <- check_not_booked(sessions, who) do
      student_id = student_id(who)

      parsed = %{
        "student_id" => student_id,
        "slot_id" => slot.id,
        "package_id" => package.id,
        "session_ids" => Enum.map(sessions, & &1.id),
        "custom_amount" => input["custom_amount"],
        "note" => input["note"],
        "signup_request_id" => request && request.id,
        "new_student" => new_student(who),
        "link_line_user_id" => link_line_user_id(who),
        "student_name" => student_name(who),
        "slot_label" => Fmt.slot_title(slot.label),
        "slot_weekday" => slot.weekday,
        "slot_time" => Fmt.time_range(slot.start_time, slot.end_time),
        "month" => Calendar.strftime(month, "%Y-%m"),
        "session_dates" => Enum.map(sessions, &Date.to_iso8601(&1.date)),
        "package_name" => package.name,
        "price_per_class" => package.price_per_class,
        "price" => Catalog.price_for(package, length(sessions))
      }

      {:ok, %{student_id: student_id, parsed: parsed}}
    end
  end

  # Spec 2026-10-07 §2, in order: the claim records the Purchase, so it runs
  # last; `confirm_draft/2`'s transaction rolls everything back if it fails.
  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <- apply_student(attrs),
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
           }),
         record = {"Ganesha.Sales.Purchase", purchase.id},
         :ok <- claim_request(attrs["signup_request_id"], record) do
      {:ok, record}
    end
  end

  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    month = Summary.month_name(parsed["month"], locale)
    weekday = Summary.weekday(parsed["slot_weekday"], locale)
    count = length(parsed["session_ids"] || [])
    owed = Summary.money(parsed["custom_amount"] || parsed["price"])
    class = Summary.words([weekday, parsed["slot_time"], parsed["slot_label"]])

    case {parsed["new_student"], locale} do
      {nil, "en"} ->
        "Enroll #{name} in #{class} for #{month}: #{count} classes, #{owed}"

      {nil, _} ->
        "幫 #{name} 報名#{month} #{class}，#{count} 堂 #{owed}"

      {_new, "en"} ->
        "Add new student #{name} and enroll #{name} in #{class} for #{month}: " <>
          "#{count} classes, #{owed}"

      {_new, _} ->
        "新增學生 #{name} 並幫 #{name} 報名#{month} #{class}，#{count} 堂 #{owed}"
    end
  end

  defp fetch_request(nil), do: {:ok, nil}

  defp fetch_request(id) when is_integer(id) do
    case Assistant.get_pending_request("signup_request", id) do
      nil ->
        {:error,
         "signup_request_id #{id} is not a pending sign-up request; it may have been " <>
           "handled already. Ask the teacher before enrolling anyone for it"}

      request ->
        {:ok, request}
    end
  end

  defp fetch_request(_id),
    do: {:error, "signup_request_id must be the integer N of a sign-up request"}

  # Who is enrolled: `{:existing, student, line_user_id_to_link | nil}` or
  # `{:new, %{"display_name", "line_user_id"}}` (spec 2026-10-07 §2 table).
  defp resolve_student(%{"student_id" => id}, request) when not is_nil(id) do
    with {:ok, student} <- fetch(:student, id),
         {:ok, link} <- line_link(student, request),
         do: {:ok, {:existing, student, link}}
  end

  defp resolve_student(%{"new_student_name" => name}, nil) when not is_nil(name),
    do:
      {:error,
       "new_student_name only works with signup_request_id; for anyone else, " <>
         "propose add_student first"}

  defp resolve_student(_input, nil), do: {:error, needs_student()}

  defp resolve_student(input, request) do
    line_user_id = request.parsed["line_user_id"]

    case People.find_by_line_user_id(line_user_id) do
      %People.Student{} = student -> {:ok, {:existing, student, nil}}
      nil -> new_student_named(input["new_student_name"], line_user_id)
    end
  end

  defp new_student_named(name, line_user_id) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, needs_student()}
      trimmed -> {:ok, {:new, %{"display_name" => trimmed, "line_user_id" => line_user_id}}}
    end
  end

  defp new_student_named(_name, _line_user_id), do: {:error, needs_student()}

  defp needs_student,
    do: "enroll needs student_id, or new_student_name together with signup_request_id"

  # The request's LINE user id is linked when the student has none and no
  # other student holds it; someone else holding it (a parent signing up a
  # child) links nothing.
  defp line_link(_student, nil), do: {:ok, nil}

  defp line_link(student, request) do
    line_user_id = request.parsed["line_user_id"]

    cond do
      is_nil(line_user_id) or student.line_user_id == line_user_id ->
        {:ok, nil}

      not is_nil(student.line_user_id) ->
        {:error,
         "#{student.display_name} is linked to a different LINE account than this " <>
           "sign-up request; ask the teacher which student it is"}

      People.find_by_line_user_id(line_user_id) ->
        {:ok, nil}

      true ->
        {:ok, line_user_id}
    end
  end

  defp student_id({:existing, student, _link}), do: student.id
  defp student_id({:new, _new}), do: nil

  defp student_name({:existing, student, _link}), do: student.display_name
  defp student_name({:new, new}), do: new["display_name"]

  defp new_student({:new, new}), do: new
  defp new_student(_who), do: nil

  defp link_line_user_id({:existing, _student, link}), do: link
  defp link_line_user_id(_who), do: nil

  # A new student whose LINE user id was linked meanwhile must not get a
  # second student (spec 2026-10-07 §2).
  defp apply_student(%{"new_student" => %{"display_name" => name, "line_user_id" => line_id}}) do
    case People.find_by_line_user_id(line_id) do
      nil -> People.create_student(%{display_name: name, line_user_id: line_id})
      _linked -> {:error, :line_user_id_taken}
    end
  end

  defp apply_student(attrs) do
    with {:ok, student} <- load(:student, attrs["student_id"]) do
      case attrs["link_line_user_id"] do
        nil -> {:ok, student}
        line_user_id -> People.link_line_user_id(student, line_user_id)
      end
    end
  end

  defp claim_request(nil, _record), do: :ok
  defp claim_request(id, record), do: Assistant.claim_request("signup_request", id, record)

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

  defp check_active({:new, _new}), do: :ok
  defp check_active({:existing, %{active: true}, _link}), do: :ok

  defp check_active({:existing, student, _link}),
    do: {:error, "#{student.display_name} is inactive"}

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

  # A new student has bought nothing, so the package must be open to anyone.
  defp check_available(package, {:new, _new}) do
    if Catalog.package_available?(package, []),
      do: :ok,
      else: {:error, "#{package.name} is closed to new students"}
  end

  defp check_available(package, {:existing, student, _link}) do
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

  defp check_not_booked(_sessions, {:new, _new}), do: :ok

  defp check_not_booked(sessions, {:existing, student, _link}) do
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
end
