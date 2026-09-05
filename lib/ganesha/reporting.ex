defmodule Ganesha.Reporting do
  @moduledoc """
  Derived numbers: what is owed, what came in, and how close the month is to the
  營業稅 起徵點.

  Purchases have no month column, so any period is reached through the dates of
  their attendance rows. Revenue is the exception: it is keyed on `paid_on`,
  because revenue is about when the money arrived.
  """

  import Ecto.Query, warn: false
  alias Ganesha.People
  alias Ganesha.Repo
  alias Ganesha.Roster.Attendance
  alias Ganesha.Sales
  alias Ganesha.Sales.{Payment, Purchase}
  alias Ganesha.Studio.Session

  # 營業稅 起徵點 for 勞務 (services) is NT$50,000/month from 114年 onward.
  @monthly_threshold 50_000
  # Warn from 90%, leaving room to react before the cliff. Crossing obliges
  # 稅籍登記, back-assessed to day one of that month if registration is late.
  @warn_ratio 0.9

  def monthly_threshold, do: @monthly_threshold

  @spec outstanding_for_student(integer()) :: integer()
  def outstanding_for_student(student_id) do
    payable =
      Repo.all(from p in Purchase, where: p.student_id == ^student_id)
      |> Enum.map(&Sales.payable/1)
      |> Enum.sum()

    confirmed =
      Repo.one(
        from pay in Payment,
          join: pur in Purchase,
          on: pur.id == pay.purchase_id,
          where: pur.student_id == ^student_id and pay.state == "confirmed",
          select: coalesce(sum(pay.amount), 0)
      )

    payable - confirmed
  end

  @doc "Every student with a non-zero balance, largest first."
  def outstanding_by_student do
    People.list_students()
    |> Enum.map(&%{student: &1, outstanding: outstanding_for_student(&1.id)})
    |> Enum.reject(&(&1.outstanding == 0))
    |> Enum.sort_by(& &1.outstanding, :desc)
  end

  @spec revenue_for_month(Date.t()) :: integer()
  def revenue_for_month(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Date.end_of_month(month)

    Repo.one(
      from pay in Payment,
        where: pay.state == "confirmed" and pay.paid_on >= ^first and pay.paid_on <= ^last,
        select: coalesce(sum(pay.amount), 0)
    )
  end

  @doc "Where a month sits against the tax registration threshold."
  def tax_threshold_status(%Date{} = month) do
    revenue = revenue_for_month(month)

    %{
      revenue: revenue,
      threshold: @monthly_threshold,
      ratio: revenue / @monthly_threshold,
      warn?: revenue >= @monthly_threshold * @warn_ratio
    }
  end

  @doc "The first and last dates a purchase's attendance rows fall on, for display."
  def purchase_period(purchase_id) do
    Repo.one(
      from a in Attendance,
        join: s in Session,
        on: s.id == a.session_id,
        where: a.purchase_id == ^purchase_id,
        select: %{first: min(s.date), last: max(s.date)}
    )
  end
end
