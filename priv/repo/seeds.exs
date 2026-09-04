# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Ganesha.Repo.insert!(%Ganesha.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# The studio has exactly one user and registration is closed, so the account
# is seeded here. Override with TEACHER_EMAIL / TEACHER_PASSWORD.
teacher_email = System.get_env("TEACHER_EMAIL") || "teacher@example.com"
teacher_password = System.get_env("TEACHER_PASSWORD") || "change-me-please-1234"

case Ganesha.Accounts.get_user_by_email(teacher_email) do
  nil ->
    {:ok, user} = Ganesha.Accounts.register_user(%{email: teacher_email})

    {:ok, user} =
      user
      |> Ganesha.Accounts.User.confirm_changeset()
      |> Ganesha.Repo.update()

    {:ok, {_user, _expired_tokens}} =
      Ganesha.Accounts.update_user_password(user, %{password: teacher_password})

    IO.puts("Seeded teacher account: #{teacher_email}")

  _user ->
    IO.puts("Teacher account already present: #{teacher_email}")
end
