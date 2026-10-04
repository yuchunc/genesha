defmodule Ganesha.Assistant.Tasks.StudentSummary do
  @moduledoc """
  `student_summary` (spec §3.1 #4): owed, purchases, upcoming Sessions, open Credits.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Reporting, Roster, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup

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
      Sessions, and open makeup Credits.\
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
      purchases = Sales.list_purchases_for_student(student.id)
      upcoming = upcoming_sessions(student.id, ctx.today)
      credits = Roster.available_credits(student.id, ctx.today)

      data =
        "#{student.display_name} (student #{student.id}): owes #{Format.money(owed)}, " <>
          "#{length(credits)} open credit(s)" <>
          purchases_data(purchases) <>
          upcoming_data(upcoming, ctx.locale)

      {:ok, %{data: data}}
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

  defp purchases_data([]), do: "; 0 purchase(s)"

  defp purchases_data(purchases) do
    "; #{length(purchases)} purchase(s): " <>
      Enum.map_join(purchases, ", ", fn purchase ->
        paid = Format.money(Sales.confirmed_paid(purchase.id))
        payable = Format.money(Sales.payable(purchase))
        "#{purchase.package.name} paid #{paid} of #{payable}"
      end)
  end

  defp upcoming_data([], _locale), do: ""

  defp upcoming_data(sessions, locale) do
    "; upcoming: " <>
      Enum.map_join(sessions, ", ", fn session ->
        "Session #{session.id} #{Lookup.session_title(session, locale)}"
      end)
  end
end
