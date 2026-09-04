defmodule Ganesha.People do
  @moduledoc "Students and the names they are known by."

  import Ecto.Query, warn: false
  alias Ganesha.People.{Student, StudentAlias}
  alias Ganesha.Repo

  def list_students do
    Repo.all(from s in Student, order_by: [desc: s.active, asc: s.display_name])
  end

  def list_active_students do
    Repo.all(from s in Student, where: s.active, order_by: s.display_name)
  end

  def get_student!(id), do: Student |> Repo.get!(id) |> Repo.preload(:aliases)

  def create_student(attrs) do
    %Student{} |> Student.changeset(attrs) |> Repo.insert()
  end

  def update_student(%Student{} = student, attrs) do
    student |> Student.changeset(attrs) |> Repo.update()
  end

  def change_student(%Student{} = student, attrs \\ %{}) do
    Student.changeset(student, attrs)
  end

  def add_alias(%Student{} = student, alias_text) do
    %StudentAlias{}
    |> StudentAlias.changeset(%{student_id: student.id, alias: alias_text})
    |> Repo.insert()
  end

  def find_by_alias(nil), do: nil

  def find_by_alias(alias_text) do
    Repo.one(
      from s in Student,
        join: a in StudentAlias,
        on: a.student_id == s.id,
        where: a.alias == ^alias_text
    )
  end

  def find_by_line_user_id(nil), do: nil

  def find_by_line_user_id(line_user_id) do
    Repo.get_by(Student, line_user_id: line_user_id)
  end
end
