defmodule Ganesha.Reporting do
  @moduledoc """
  Derived numbers: what is owed, what came in, and how close the month is to the
  營業稅 起徵點.

  Purchases have no month column, so any period is reached through the dates of
  their attendance rows. Revenue is the exception: it is keyed on `paid_on`,
  because revenue is about when the money arrived.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Clock
  alias Ganesha.People
  alias Ganesha.Reporting.MonthlyClose
  alias Ganesha.Repo
  alias Ganesha.Roster.{Attendance, Credit}
  alias Ganesha.Sales
  alias Ganesha.Sales.{Payment, Purchase}
  alias Ganesha.Studio
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

  @doc "Every student with a positive balance, largest first."
  def outstanding_by_student do
    payable_by_student =
      Repo.all(
        from p in Purchase,
          group_by: p.student_id,
          select: {p.student_id, sum(coalesce(p.custom_amount, p.list_price))}
      )
      |> Map.new()

    confirmed_by_student =
      Repo.all(
        from pay in Payment,
          join: pur in Purchase,
          on: pur.id == pay.purchase_id,
          where: pay.state == "confirmed",
          group_by: pur.student_id,
          select: {pur.student_id, sum(pay.amount)}
      )
      |> Map.new()

    People.list_students()
    |> Enum.map(fn student ->
      payable = Map.get(payable_by_student, student.id, 0)
      confirmed = Map.get(confirmed_by_student, student.id, 0)
      %{student: student, outstanding: payable - confirmed}
    end)
    |> Enum.reject(&(&1.outstanding <= 0))
    |> Enum.sort_by(& &1.outstanding, :desc)
  end

  @spec revenue_for_month(Date.t()) :: integer()
  def revenue_for_month(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Clock.end_of_month(month)

    Repo.one(
      from pay in Payment,
        where: pay.state == "confirmed" and pay.paid_on >= ^first and pay.paid_on <= ^last,
        select: coalesce(sum(pay.amount), 0)
    )
  end

  @doc """
  Confirmed revenue for a month, grouped by payment method.

  Every method is present even at zero, so a caller never has to guard a
  missing key. Returned as an ordered list, not a map — the order is
  `Payment.methods/0`'s, and a plain map cannot promise that.
  """
  @spec revenue_by_method_for_month(Date.t()) :: [{String.t(), integer()}]
  def revenue_by_method_for_month(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Clock.end_of_month(month)

    totals =
      Repo.all(
        from pay in Payment,
          where: pay.state == "confirmed" and pay.paid_on >= ^first and pay.paid_on <= ^last,
          group_by: pay.method,
          select: {pay.method, sum(pay.amount)}
      )
      |> Map.new()

    ordered_methods(totals)
  end

  defp ordered_methods(totals) do
    for method <- Payment.methods(), do: {method, Map.get(totals, method, 0)}
  end

  @doc """
  Freezes a month's confirmed revenue, its breakdown by payment method, and
  the tax threshold in effect, into a permanent `MonthlyClose` row.

  Upserts — calling this again for an already-closed month overwrites it.
  That's how a payment confirmed after its month has closed refreshes the
  frozen snapshot.
  """
  @spec close_month(Date.t()) :: {:ok, MonthlyClose.t()}
  def close_month(%Date{} = month) do
    first = Date.beginning_of_month(month)

    attrs = %{
      month: first,
      revenue: revenue_for_month(first),
      revenue_by_method: Map.new(revenue_by_method_for_month(first)),
      tax_threshold: @monthly_threshold
    }

    %MonthlyClose{}
    |> MonthlyClose.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:revenue, :revenue_by_method, :tax_threshold, :updated_at]},
      conflict_target: :month
    )
  end

  @doc "The frozen snapshot for a month, or nil if it hasn't closed yet."
  @spec get_closed_month(Date.t()) :: MonthlyClose.t() | nil
  def get_closed_month(%Date{} = month) do
    Repo.get_by(MonthlyClose, month: Date.beginning_of_month(month))
  end

  @doc """
  Closed months strictly before `before`, most recent first — the page of
  history `MoneyLive`'s 歷史款項 list shows.
  """
  @spec list_closed_months(before: Date.t(), limit: pos_integer(), offset: non_neg_integer()) ::
          [MonthlyClose.t()]
  def list_closed_months(opts) do
    before = Keyword.fetch!(opts, :before)
    limit = Keyword.fetch!(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    Repo.all(
      from c in MonthlyClose,
        where: c.month < ^Date.beginning_of_month(before),
        order_by: [desc: c.month],
        limit: ^limit,
        offset: ^offset
    )
  end

  @doc """
  A cycle's revenue and per-method breakdown — live for the current month
  or one that hasn't closed yet, frozen for one that has.
  """
  @spec cycle_summary(Date.t()) :: %{revenue: integer(), by_method: [{String.t(), integer()}]}
  def cycle_summary(%Date{} = month) do
    case get_closed_month(month) do
      nil ->
        %{revenue: revenue_for_month(month), by_method: revenue_by_method_for_month(month)}

      %MonthlyClose{} = closed ->
        %{revenue: closed.revenue, by_method: ordered_methods(closed.revenue_by_method)}
    end
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

  @doc """
  The first and last dates a purchase's attendance rows fall on, for display.
  Returns `nil` when the purchase has no attendance rows yet.
  """
  def purchase_period(purchase_id) do
    case Repo.one(
           from a in Attendance,
             join: s in Session,
             on: s.id == a.session_id,
             where: a.purchase_id == ^purchase_id,
             select: %{first: min(s.date), last: max(s.date)}
         ) do
      %{first: nil, last: nil} -> nil
      period -> period
    end
  end

  @doc """
  The month laid out as one lane per weekly class, each lane carrying its dates
  and what is on them.

  This is the shape of a studio's month: four recurring slots, three or four
  dates each. Headcounts come from a single grouped query rather than a roster
  lookup per session, because a four-lane month would otherwise cost sixteen.

  Returns `[%{slot: %Slot{}, sessions: [%{session: %Session{}, total: n,
  expected: n, no_show: n, makeup: n}]}]`.
  """
  def month_lanes(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Clock.end_of_month(month)

    tallies =
      Repo.all(
        from a in Attendance,
          join: s in Session,
          on: s.id == a.session_id,
          where: s.date >= ^first and s.date <= ^last,
          group_by: [a.session_id, a.kind, a.state],
          select: {a.session_id, a.kind, a.state, count(a.id)}
      )
      |> Enum.group_by(fn {session_id, _, _, _} -> session_id end)
      |> Map.new(fn {session_id, rows} -> {session_id, tally(rows)} end)

    Enum.map(Studio.list_active_slots(), fn slot ->
      sessions =
        slot
        |> Studio.sessions_for_slot_in_month(month)
        |> Enum.map(fn session ->
          tallies
          |> Map.get(session.id, empty_tally())
          # The slot is already in hand — it is the one we queried by — so
          # attach it rather than round-tripping a preload per session.
          |> Map.put(:session, %{session | slot: slot})
        end)

      %{slot: slot, sessions: sessions}
    end)
  end

  defp empty_tally, do: %{total: 0, expected: 0, no_show: 0, makeup: 0}

  # Kind and state are independent: a makeup can also be a no-show, so both
  # counters have to see the same row rather than one claiming it.
  defp tally(rows) do
    Enum.reduce(rows, empty_tally(), fn {_id, kind, state, count}, acc ->
      acc
      |> Map.update!(:total, &(&1 + count))
      |> Map.update!(:expected, &if(state == "expected", do: &1 + count, else: &1))
      |> Map.update!(:no_show, &if(state == "no_show", do: &1 + count, else: &1))
      |> Map.update!(:makeup, &if(kind == "makeup", do: &1 + count, else: &1))
    end)
  end

  @doc """
  Makeup entitlements that are still spendable, soonest expiry first.

  These are the studio's open promises. An unspent credit that expires is a
  class a student paid for and never received, which is why the dashboard
  surfaces them before they lapse. Credits that never expire sort last: they
  are not urgent.

  Ordering is done in Elixir rather than SQL so the nil-expiry case does not
  depend on how the backend sorts NULLs.
  """
  def open_credits(as_of \\ nil) do
    today = as_of || Clock.today()

    Repo.all(
      from c in Credit,
        where: is_nil(c.consumed_by_attendance_id),
        where: is_nil(c.expires_on) or c.expires_on >= ^today,
        preload: [:student]
    )
    |> Enum.sort_by(fn credit ->
      {is_nil(credit.expires_on), credit.expires_on || ~D[9999-12-31], credit.id}
    end)
  end

  @doc """
  Every payment recorded against a month, newest first, whatever its state.

  Claimed rows are included deliberately: a payment she has not confirmed yet
  is the thing she most needs to see, and excluding it would hide her own
  outstanding work.
  """
  def payments_for_month(%Date{} = month) do
    first = Date.beginning_of_month(month)
    last = Clock.end_of_month(month)

    Repo.all(
      from pay in Payment,
        where: pay.paid_on >= ^first and pay.paid_on <= ^last,
        order_by: [desc: pay.paid_on, desc: pay.id],
        preload: [purchase: [:student, :package]]
    )
  end
end
