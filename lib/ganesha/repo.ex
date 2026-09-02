defmodule Ganesha.Repo do
  use Ecto.Repo,
    otp_app: :ganesha,
    adapter: Ecto.Adapters.SQLite3
end
