defmodule Ganesha.Assistant.Tasks.MonthMoney do
  @moduledoc """
  `month_money` (spec §3.1 #5): revenue, who owes, tax threshold for a month.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Reporting
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.Lookup

  @impl true
  def name, do: "month_money"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      Revenue collected in a month, every student who still owes money, and how close \
      the month is to the tax registration threshold. Omit month for the current month. \
      Use show_card for the money card.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          month: %{type: "string", description: "ISO 8601 date in that month, e.g. 2026-10-01"}
        }
      }
    }
  end

  @impl true
  def answer(input, ctx) do
    with %Date{} = month <- Lookup.parse_month(input["month"], ctx.today) do
      answer_month(month, ctx)
    end
  end

  defp answer_month(month, ctx) do
    revenue = Reporting.revenue_for_month(month)
    tax = Reporting.tax_threshold_status(month)
    owing = Reporting.outstanding_by_student()
    owed_total = owing |> Enum.map(& &1.outstanding) |> Enum.sum()
    month_label = Format.month_title(month, ctx.locale)

    payload = %{
      "month" => month_label,
      "revenue" => Format.money(revenue),
      "tax_warn" => tax.warn?,
      "owed_total" => Format.money(owed_total),
      "debtors" =>
        Enum.map(owing, fn %{student: student, outstanding: amount} ->
          %{"name" => student.display_name, "amount" => Format.money(amount)}
        end)
    }

    data =
      "#{month_label}: revenue #{Format.money(revenue)}, #{tax_data(tax)}. " <>
        owing_data(owing, owed_total)

    {:ok, %{data: data, card: {:money, payload}}}
  end

  defp tax_data(tax) do
    progress = "#{round(tax.ratio * 100)}% of the #{Format.money(tax.threshold)} tax threshold"
    if tax.warn?, do: progress <> " (close to it)", else: progress
  end

  defp owing_data([], _total), do: "Nobody owes money"

  defp owing_data(owing, total) do
    "#{length(owing)} student(s) owe #{Format.money(total)}: " <>
      Enum.map_join(owing, "; ", fn %{student: student, outstanding: amount} ->
        "#{student.display_name} (student #{student.id}) #{Format.money(amount)}"
      end)
  end
end
