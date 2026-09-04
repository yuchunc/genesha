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
    password_valid? =
      %Ganesha.Accounts.User{}
      |> Ganesha.Accounts.User.password_changeset(%{password: teacher_password},
        hash_password: false
      )
      |> Map.fetch!(:valid?)

    unless password_valid? do
      raise """
      TEACHER_PASSWORD must be at least 12 characters (and at most 72 bytes).
      Fix the env var and retry so the teacher row is created cleanly.
      """
    end

    result =
      Ganesha.Repo.transact(fn ->
        with {:ok, user} <- Ganesha.Accounts.register_user(%{email: teacher_email}),
             {:ok, user} <-
               user
               |> Ganesha.Accounts.User.confirm_changeset()
               |> Ganesha.Repo.update(),
             {:ok, {user, _expired_tokens}} <-
               Ganesha.Accounts.update_user_password(user, %{password: teacher_password}) do
          {:ok, user}
        else
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, _user} ->
        IO.puts("Seeded teacher account: #{teacher_email}")

      {:error, reason} ->
        raise """
        Failed to seed teacher account: #{inspect(reason)}
        TEACHER_PASSWORD must be at least 12 characters (and at most 72 bytes).
        Fix the env var and retry so the teacher row is created cleanly.
        """
    end

  _user ->
    IO.puts("Teacher account already present: #{teacher_email}")
end

for attrs <- [
      %{name: "月課程", kind: "monthly", price_per_class: 400, included_makeups: 1},
      %{name: "單堂", kind: "drop_in", price_per_class: 450, included_makeups: 0},
      %{name: "體驗", kind: "trial", price_per_class: 450, included_makeups: 0}
    ] do
  case Ganesha.Repo.get_by(Ganesha.Catalog.Package, name: attrs.name) do
    nil -> {:ok, _} = Ganesha.Catalog.create_package(attrs)
    _existing -> :ok
  end
end

for attrs <- [
      %{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      },
      %{
        weekday: 1,
        start_time: ~T[15:30:00],
        end_time: ~T[16:45:00],
        default_style: "基礎",
        label: "午後練習｜週一 基礎瑜伽"
      },
      %{
        weekday: 3,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "流動",
        label: "早晨練習｜週三 和緩流動"
      },
      %{
        weekday: 5,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週五 基礎瑜伽"
      }
    ] do
  case Ganesha.Repo.get_by(Ganesha.Studio.Slot,
         weekday: attrs.weekday,
         start_time: attrs.start_time
       ) do
    nil -> {:ok, _} = Ganesha.Studio.create_slot(attrs)
    _existing -> :ok
  end
end
