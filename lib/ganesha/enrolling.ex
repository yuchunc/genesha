defmodule Ganesha.Enrolling do
  @moduledoc """
  The use case that joins a sale to a roster.

  Selling a month means three things happening together: a purchase, one
  attendance row per bought session, and the package's included makeup credits.
  They run in a single transaction because a purchase without attendance rows
  has no period (and so no credit expiry), and attendance rows without a
  purchase would be free classes.
  """

  alias Ganesha.{Catalog, Repo, Roster, Sales}

  @doc """
  Enrolls a student in a slot for a set of that month's sessions.

  `list_price` is a snapshot of `price_per_class * length(sessions)`;
  `custom_amount` overrides what is actually owed without disturbing it.
  """
  def enroll_month(%{sessions: []}), do: {:error, :no_sessions}

  def enroll_month(%{
        student: student,
        slot: slot,
        package: package,
        sessions: sessions,
        custom_amount: custom_amount,
        note: note
      }) do
    Repo.transaction(fn ->
      {:ok, purchase} =
        Sales.create_purchase(%{
          student_id: student.id,
          package_id: package.id,
          slot_id: slot.id,
          list_price: Catalog.price_for(package, length(sessions)),
          custom_amount: custom_amount,
          note: note
        })

      attendances =
        Enum.map(sessions, fn session ->
          case Roster.enroll(session, student, purchase) do
            {:ok, attendance} -> attendance
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      # Credits depend on attendance dates, so mint after the rows exist.
      {:ok, credits} = Roster.mint_package_credits(purchase)

      %{purchase: purchase, attendances: attendances, credits: credits}
    end)
  end

  @doc """
  Seats a single non-enrolled attendee: a drop-in or a trial.

  No `slot_id`: a one-off is not a monthly commitment to a weekday.
  Options: `:custom_amount`, `:note`.
  """
  def add_one_off(session, student, package, opts) do
    Repo.transaction(fn ->
      {:ok, purchase} =
        Sales.create_purchase(%{
          student_id: student.id,
          package_id: package.id,
          slot_id: nil,
          list_price: Catalog.price_for(package, 1),
          custom_amount: Keyword.get(opts, :custom_amount),
          note: Keyword.get(opts, :note)
        })

      case Roster.add_drop_in(session, student, purchase) do
        {:ok, attendance} -> %{purchase: purchase, attendance: attendance}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end
end
