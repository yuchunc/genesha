defmodule Ganesha.Roster do
  @moduledoc """
  Attendance rows and makeup credits.

  An attendance row is the only thing that puts a name on a date. Every kind of
  participation flows through it: a monthly enrollment, a drop-in, a trial, or a
  makeup paid for by a credit rather than by a sale.
  """

  import Ecto.Query, warn: false
  alias Ganesha.Clock
  alias Ganesha.People.Student
  alias Ganesha.Repo
  alias Ganesha.Roster.{Attendance, Credit}
  alias Ganesha.Sales.Purchase
  alias Ganesha.Studio.Session

  def create_attendance(attrs) do
    %Attendance{} |> Attendance.changeset(attrs) |> Repo.insert()
  end

  def enroll(%Session{} = session, %Student{} = student, %Purchase{} = purchase) do
    create_attendance(%{
      session_id: session.id,
      student_id: student.id,
      purchase_id: purchase.id,
      kind: "enrolled"
    })
  end

  @doc "Seats a non-enrolled attendee. The kind follows the purchase's package."
  def add_drop_in(%Session{} = session, %Student{} = student, %Purchase{} = purchase) do
    kind = if purchase_package_kind(purchase) == "trial", do: "trial", else: "drop_in"

    create_attendance(%{
      session_id: session.id,
      student_id: student.id,
      purchase_id: purchase.id,
      kind: kind
    })
  end

  defp purchase_package_kind(%Purchase{} = purchase) do
    purchase = Repo.preload(purchase, :package)
    purchase.package.kind
  end

  def mark_no_show(%Attendance{} = attendance) do
    attendance |> Attendance.changeset(%{state: "no_show"}) |> Repo.update()
  end

  def mark_expected(%Attendance{} = attendance) do
    attendance |> Attendance.changeset(%{state: "expected"}) |> Repo.update()
  end

  def get_attendance!(id) do
    Attendance |> Repo.get!(id) |> Repo.preload([:student, session: :slot])
  end

  def list_for_session(%Session{} = session) do
    Repo.all(
      from a in Attendance,
        where: a.session_id == ^session.id,
        order_by: a.id,
        preload: [:student, purchase: :package]
    )
  end

  def list_for_student(student_id) do
    Repo.all(
      from a in Attendance,
        where: a.student_id == ^student_id,
        order_by: [desc: a.id],
        preload: [session: :slot]
    )
  end

  @doc """
  Grants a monthly purchase's included makeups.

  Called once the purchase has attendance rows rather than at creation time: a
  purchase has no month of its own, so expiry is the last day of the calendar
  month of its earliest attended session, evaluated in Taipei. Idempotent via
  the partial unique index on `(origin_purchase_id, seq)`.
  """
  def mint_package_credits(%Purchase{} = purchase) do
    purchase = Repo.preload(purchase, :package)

    case {purchase.package.included_makeups, earliest_session_date(purchase)} do
      {0, _} ->
        {:ok, []}

      {_count, nil} ->
        {:ok, []}

      {count, %Date{} = earliest} ->
        expires_on = Clock.end_of_month(earliest)

        credits =
          Enum.map(1..count, fn seq ->
            attrs = %{
              student_id: purchase.student_id,
              source: "package",
              seq: seq,
              origin_purchase_id: purchase.id,
              expires_on: expires_on
            }

            case %Credit{} |> Credit.changeset(attrs) |> Repo.insert() do
              {:ok, credit} ->
                credit

              {:error, %{errors: [{_, {_, [constraint: :unique, constraint_name: _]}} | _]}} ->
                # Already minted; the partial unique index rejected the insert.
                Repo.one!(
                  from c in Credit,
                    where:
                      c.origin_purchase_id == ^purchase.id and c.seq == ^seq and
                        c.source == "package"
                )
            end
          end)

        {:ok, credits}
    end
  end

  defp earliest_session_date(%Purchase{} = purchase) do
    Repo.one(
      from a in Attendance,
        join: s in Session,
        on: s.id == a.session_id,
        where: a.purchase_id == ^purchase.id,
        select: min(s.date)
    )
  end

  @doc """
  Issues one never-expiring makeup credit per enrolled student on a cancelled
  session. Idempotent via the partial unique index on
  `(origin_session_id, student_id)`.
  """
  def issue_cancellation_credits(%Session{} = session) do
    student_ids =
      Repo.all(
        from a in Attendance,
          where: a.session_id == ^session.id and a.kind == "enrolled",
          select: a.student_id
      )

    credits =
      Enum.map(student_ids, fn student_id ->
        attrs = %{
          student_id: student_id,
          source: "cancellation",
          origin_session_id: session.id,
          expires_on: nil,
          note: session.cancel_reason
        }

        case %Credit{} |> Credit.changeset(attrs) |> Repo.insert() do
          {:ok, credit} ->
            credit

          {:error, %{errors: [{_, {_, [constraint: :unique, constraint_name: _]}} | _]}} ->
            Repo.one!(
              from c in Credit,
                where:
                  c.origin_session_id == ^session.id and c.student_id == ^student_id and
                    c.source == "cancellation"
            )
        end
      end)

    {:ok, credits}
  end

  @doc "Credits this student may still spend on a class held on `date`."
  def available_credits(student_id, %Date{} = date) do
    Repo.all(
      from c in Credit,
        where:
          c.student_id == ^student_id and is_nil(c.consumed_by_attendance_id) and
            (is_nil(c.expires_on) or c.expires_on >= ^date),
        order_by: [asc_nulls_last: c.expires_on]
    )
  end

  @doc """
  Books a makeup: creates a free attendance row and spends the credit.

  All three guards must hold — same student, unspent, and not expired on the
  session's date. Wrapped in a transaction so a row is never created without
  its credit being spent, which would silently grant a free class.
  """
  def book_makeup(%Session{} = session, %Student{} = student, %Credit{} = credit) do
    with :ok <- check_owner(credit, student),
         :ok <- check_unconsumed(credit),
         :ok <- check_not_expired(credit, session.date),
         {:ok, attendance} <- insert_makeup(session, student, credit) do
      {:ok, attendance}
    end
  end

  defp insert_makeup(session, student, credit) do
    Repo.transaction(fn ->
      attendance =
        case create_attendance(%{
               session_id: session.id,
               student_id: student.id,
               kind: "makeup",
               purchase_id: nil,
               credit_id: credit.id,
               note: credit.note
             }) do
          {:ok, attendance} -> attendance
          {:error, changeset} -> Repo.rollback(changeset)
        end

      # Compare-and-set, not an unconditional overwrite: two calls racing on
      # the same unreloaded %Credit{} (the brief's own idempotency test needs
      # Repo.reload!/1 before its second attempt to avoid exactly this) must
      # not both succeed in spending it, or one credit buys two makeup classes.
      claim = from(c in Credit, where: c.id == ^credit.id and is_nil(c.consumed_by_attendance_id))
      stamp = DateTime.utc_now() |> DateTime.truncate(:second)

      case Repo.update_all(claim,
             set: [consumed_by_attendance_id: attendance.id, updated_at: stamp]
           ) do
        {1, _} -> attendance
        {0, _} -> Repo.rollback(:credit_already_consumed)
      end
    end)
  end

  defp check_owner(%Credit{student_id: id}, %Student{id: id}), do: :ok
  defp check_owner(_credit, _student), do: {:error, :credit_not_owned}

  defp check_unconsumed(%Credit{consumed_by_attendance_id: nil}), do: :ok
  defp check_unconsumed(_credit), do: {:error, :credit_already_consumed}

  defp check_not_expired(%Credit{expires_on: nil}, _date), do: :ok

  defp check_not_expired(%Credit{expires_on: expires_on}, %Date{} = date) do
    if Date.compare(expires_on, date) == :lt, do: {:error, :credit_expired}, else: :ok
  end

  @doc "Unspent credits whose expiry has passed, for the Money screen."
  def expired_credits do
    today = Clock.today()

    Repo.all(
      from c in Credit,
        where:
          is_nil(c.consumed_by_attendance_id) and not is_nil(c.expires_on) and
            c.expires_on < ^today,
        order_by: [desc: c.expires_on],
        preload: [:student]
    )
  end
end
