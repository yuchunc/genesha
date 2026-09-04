defmodule Ganesha.Catalog do
  @moduledoc "The studio's price list."

  import Ecto.Query, warn: false
  alias Ganesha.Catalog.Package
  alias Ganesha.Repo

  def list_packages do
    Repo.all(from p in Package, order_by: [desc: p.active, asc: p.name])
  end

  def list_active_packages do
    Repo.all(from p in Package, where: p.active, order_by: p.name)
  end

  def get_package!(id), do: Repo.get!(Package, id)

  def create_package(attrs) do
    %Package{} |> Package.changeset(attrs) |> Repo.insert()
  end

  def update_package(%Package{} = package, attrs) do
    package |> Package.changeset(attrs) |> Repo.update()
  end

  def change_package(%Package{} = package, attrs \\ %{}) do
    Package.changeset(package, attrs)
  end

  @doc """
  The list price for buying `session_count` classes of this package.

  A suggestion only. The agreed number is snapshotted onto the purchase as
  `list_price`, and may be overridden there by `custom_amount`.
  """
  @spec price_for(map(), non_neg_integer()) :: non_neg_integer()
  def price_for(%{price_per_class: per_class}, session_count)
      when is_integer(session_count) and session_count >= 0 do
    per_class * session_count
  end
end
