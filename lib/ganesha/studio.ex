defmodule Ganesha.Studio do
  @moduledoc "Recurring weekly slots and the dated sessions they generate."

  import Ecto.Query, warn: false
  alias Ganesha.Clock
  alias Ganesha.Repo
  alias Ganesha.Studio.{Session, Slot}

  def list_slots do
    Repo.all(from s in Slot, order_by: [desc: s.active, asc: s.weekday, asc: s.start_time])
  end

  def list_active_slots do
    Repo.all(from s in Slot, where: s.active, order_by: [asc: s.weekday, asc: s.start_time])
  end

  def get_slot!(id), do: Repo.get!(Slot, id)

  def create_slot(attrs), do: %Slot{} |> Slot.changeset(attrs) |> Repo.insert()

  def update_slot(%Slot{} = slot, attrs), do: slot |> Slot.changeset(attrs) |> Repo.update()

  @doc "Creates a single session. Prefer `generate_month/2` for a whole month."
  def create_session(attrs), do: %Session{} |> Session.changeset(attrs) |> Repo.insert()

  def get_session!(id), do: Session |> Repo.get!(id) |> Repo.preload(:slot)

  @doc """
  Creates a session for every date in `month` matching the slot's weekday.

  Idempotent: dates that already have a session are skipped, so re-running it
  neither duplicates rows nor overwrites a style override or a cancellation.
  Returns all of the month's sessions for the slot, not only the new ones.
  """
  def generate_month(%Slot{} = slot, %Date{} = month) do
    Repo.transaction(fn ->
      existing = slot |> sessions_for_slot_in_month(month) |> MapSet.new(& &1.date)

      month
      |> dates_in_month_on(slot.weekday)
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> Enum.reduce_while(:ok, fn date, :ok ->
        case create_session(%{slot_id: slot.id, date: date, style: slot.default_style}) do
          {:ok, _session} -> {:cont, :ok}
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      sessions_for_slot_in_month(slot, month)
    end)
  end

  defp dates_in_month_on(%Date{} = month, weekday) do
    Date.range(Date.beginning_of_month(month), Clock.end_of_month(month))
    |> Enum.filter(&(Date.day_of_week(&1) == weekday))
  end

  def sessions_for_slot_in_month(%Slot{} = slot, %Date{} = month) do
    Repo.all(
      from s in Session,
        where:
          s.slot_id == ^slot.id and s.date >= ^Date.beginning_of_month(month) and
            s.date <= ^Clock.end_of_month(month),
        order_by: s.date
    )
  end

  @doc """
  Every session in `month`, recurring and standalone alike, ordered by date.

  Preloads `:slot` — callers tell a recurring session from a standalone one
  by whether `session.slot` is `nil`.
  """
  def sessions_in_month(%Date{} = month) do
    Repo.all(
      from s in Session,
        where: s.date >= ^Date.beginning_of_month(month) and s.date <= ^Clock.end_of_month(month),
        order_by: [asc: s.date, asc: s.id],
        preload: [:slot]
    )
  end

  @doc """
  Runs `generate_month/2` for every active slot, in one transaction.

  Backs the "copy last month's classes" prompt: idempotent, so it never
  duplicates or overwrites a cancellation or style override already made
  this month. Returns the number of sessions newly created (not the
  month's total).
  """
  def copy_month(%Date{} = month) do
    Repo.transaction(fn ->
      Enum.reduce(list_active_slots(), 0, fn slot, created ->
        before_count = slot |> sessions_for_slot_in_month(month) |> length()
        {:ok, sessions} = generate_month(slot, month)
        created + (length(sessions) - before_count)
      end)
    end)
  end

  def set_style(%Session{} = session, style) do
    session |> Session.changeset(%{style: style}) |> Repo.update()
  end

  @doc """
  Marks a session cancelled.

  Credit issuance is deliberately NOT done here: `Ganesha.Roster` owns credits,
  and the caller issues them so the two steps are visible at the call site.
  """
  def cancel_session(%Session{} = session, reason) do
    session |> Session.cancellation_changeset(reason) |> Repo.update()
  end

  @doc "The next scheduled session today or later, in Taipei terms."
  def next_session do
    today = Clock.today()

    Repo.one(
      from s in Session,
        left_join: slot in assoc(s, :slot),
        where: s.date >= ^today and s.state == "scheduled",
        order_by: [asc: s.date, asc: fragment("coalesce(?, ?)", slot.start_time, s.start_time)],
        limit: 1,
        preload: [slot: slot]
    )
  end

  @doc "Scheduled sessions with a date in the inclusive range `[from, to]`."
  def sessions_between(%Date{} = from, %Date{} = to) do
    Repo.all(
      from s in Session,
        left_join: slot in assoc(s, :slot),
        where: s.date >= ^from and s.date <= ^to and s.state == "scheduled",
        order_by: [asc: s.date, asc: fragment("coalesce(?, ?)", slot.start_time, s.start_time)],
        preload: [slot: slot]
    )
  end
end
