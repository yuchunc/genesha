defmodule Ganesha.Assistant.Tasks.BookOneOff do
  @moduledoc """
  `book_one_off` (spec §3.1 #13): a 單堂 or 體驗 in one Session through
  `Ganesha.Enrolling.add_one_off/4`, so the booking always has a purchase
  behind it (ADR 0001 — it replaces the old raw attendance Draft).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Summary
  alias Ganesha.Assistant.Tasks.Lookup
  alias GaneshaWeb.Fmt

  @apply_keys ~w(student_id session_id package_id custom_amount note)
  @one_off_kinds ~w(drop_in trial)

  @impl true
  def name, do: "book_one_off"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Book a student into one Session as a single class (單堂) or a trial (體驗). This only \
      proposes a Draft; the purchase and the booking are created when the teacher taps \
      Confirm. Use ids from the studio snapshot; package_id must be a drop_in or trial \
      package.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          session_id: %{type: "integer"},
          package_id: %{type: "integer"},
          custom_amount: %{
            type: "integer",
            description: "NT$ owed instead of the package price, only if the teacher says so"
          },
          note: %{type: "string"}
        },
        required: ["student_id", "session_id", "package_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, student} <- fetch(:student, input["student_id"]),
         {:ok, session} <- fetch(:session, input["session_id"]),
         {:ok, package} <- fetch(:package, input["package_id"]),
         :ok <- check_scheduled(session),
         :ok <- check_one_off(package),
         :ok <- check_available(package, student),
         :ok <- check_amount(input["custom_amount"]),
         roster = Roster.list_for_session(session),
         :ok <- check_not_booked(roster, student) do
      parsed = %{
        "student_id" => student.id,
        "session_id" => session.id,
        "package_id" => package.id,
        "custom_amount" => input["custom_amount"],
        "note" => input["note"],
        "student_name" => student.display_name,
        "package_name" => package.name,
        "package_kind" => package.kind,
        "price" => Catalog.price_for(package, 1),
        "session_date" => Date.to_iso8601(session.date),
        "session_label" => Fmt.session_label(session),
        "session_time" => Fmt.session_time_range(session),
        "before_count" => length(roster)
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, student} <- load(:student, attrs["student_id"]),
         {:ok, session} <- Lookup.load_session(attrs["session_id"]),
         {:ok, package} <- load(:package, attrs["package_id"]),
         :ok <- still_scheduled(session),
         :ok <- still_available(package, student),
         :ok <- same_price(package, parsed["price"]),
         {:ok, %{purchase: purchase}} <-
           Enrolling.add_one_off(session, student, package,
             custom_amount: attrs["custom_amount"],
             note: attrs["note"]
           ) do
      {:ok, {"Ganesha.Sales.Purchase", purchase.id}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"

    session =
      Summary.words([
        Summary.day(parsed["session_date"], locale),
        parsed["session_time"],
        parsed["session_label"]
      ])

    kind = Summary.kind(parsed["package_kind"], locale)
    owed = Summary.money(parsed["custom_amount"] || parsed["price"])

    if locale == "en",
      do: "Book #{name} into #{session} as a #{kind}, #{owed}",
      else: "幫 #{name} 排 #{session} #{kind} #{owed}"
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
  defp get(:session, id), do: Studio.get_session(id)
  defp get(:package, id), do: Catalog.get_package(id)

  defp check_scheduled(%{state: "scheduled"}), do: :ok

  defp check_scheduled(session),
    do: {:error, "session #{session.id} on #{session.date} is cancelled"}

  defp still_scheduled(%{state: "scheduled"}), do: :ok
  defp still_scheduled(_session), do: {:error, :session_cancelled}

  defp check_one_off(%{kind: kind}) when kind in @one_off_kinds, do: :ok

  defp check_one_off(package),
    do: {:error, "#{package.name} is not a 單堂 or 體驗 package; use a drop_in or trial package_id"}

  defp check_available(package, student) do
    if available?(package, student),
      do: :ok,
      else: {:error, "#{package.name} is closed to #{student.display_name}"}
  end

  defp still_available(package, student) do
    if available?(package, student), do: :ok, else: {:error, :package_unavailable}
  end

  defp same_price(package, price) do
    if Catalog.price_for(package, 1) == price, do: :ok, else: {:error, :price_changed}
  end

  defp available?(package, student),
    do: Catalog.package_available?(package, Sales.purchased_package_ids_for_student(student.id))

  defp check_amount(nil), do: :ok
  defp check_amount(amount) when is_integer(amount) and amount >= 0, do: :ok

  defp check_amount(_amount),
    do: {:error, "custom_amount must be a whole NT$ amount of 0 or more"}

  defp check_not_booked(roster, student) do
    if Enum.any?(roster, &(&1.student_id == student.id)),
      do: {:error, "#{student.display_name} is already booked in that session"},
      else: :ok
  end
end
