defmodule Ganesha.Roster do
  @moduledoc """
  Attendance rows and makeup credits.

  An attendance row is the only thing that puts a name on a date. Every kind of
  participation flows through it: a monthly enrollment, a drop-in, a trial, or a
  makeup paid for by a credit rather than by a sale.
  """

  import Ecto.Query, warn: false
  alias Ganesha.People.Student
  alias Ganesha.Repo
  alias Ganesha.Roster.Attendance
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
end
