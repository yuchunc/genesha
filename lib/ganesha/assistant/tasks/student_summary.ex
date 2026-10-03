defmodule Ganesha.Assistant.Tasks.StudentSummary do
  @moduledoc """
  `student_summary` (spec §3.1 #4): owed, purchases, upcoming Sessions, open Credits.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Reporting, Roster, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup
  alias GaneshaWeb.Fmt

  @upcoming_limit 5

  @impl true
  def name, do: "student_summary"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Summarize one student: what they owe, their purchases and payments, upcoming \
      Sessions, and open makeup Credits. Use show_card for the summary card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{student_id: %{type: "integer"}},
        required: ["student_id"]
      }
    }
  end

  @impl true
  def answer(%{"student_id" => student_id}, ctx) do
    with {:ok, student} <- Lookup.fetch_student(student_id) do
      owed = Reporting.outstanding_for_student(student.id)

      purchases =
        Enum.map(Sales.list_purchases_for_student(student.id), fn purchase ->
          %{
            "package" => purchase.package.name,
            "paid" => Format.money(Sales.confirmed_paid(purchase.id)),
            "payable" => Format.money(Sales.payable(purchase))
          }
        end)

      upcoming = upcoming_sessions(student.id, ctx.today)
      credits = Roster.available_credits(student.id, ctx.today)

      payload = %{
        "name" => student.display_name,
        "owed" => Format.money(owed),
        "purchases" => purchases,
        "upcoming" =>
          Enum.map(upcoming, fn session ->
            %{
              "day" => Format.session_day(session.date, ctx.locale),
              "label" => Fmt.session_label(session)
            }
          end),
        "credits" => length(credits)
      }

      data =
        "#{student.display_name} (student #{student.id}): owes #{Format.money(owed)}, " <>
          "#{length(purchases)} purchase(s), #{length(credits)} open credit(s)" <>
          upcoming_data(upcoming, ctx.locale)

      {:ok, %{data: data, card: {:student, payload}}}
    end
  end

  def answer(_input, _ctx), do: {:error, "student_id must be a student id from the snapshot"}

  # Scheduled Sessions from today on, soonest first.
  defp upcoming_sessions(student_id, today) do
    student_id
    |> Roster.list_for_student()
    |> Enum.map(& &1.session)
    |> Enum.filter(&(&1.state == "scheduled" and Date.compare(&1.date, today) != :lt))
    |> Enum.sort_by(& &1.date, Date)
    |> Enum.take(@upcoming_limit)
  end

  defp upcoming_data([], _locale), do: ""

  defp upcoming_data(sessions, locale) do
    "; upcoming: " <>
      Enum.map_join(sessions, ", ", fn session ->
        "Session #{session.id} #{Lookup.session_title(session, locale)}"
      end)
  end
end
