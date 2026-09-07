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

  @doc """
  Active packages, plus inactive ones still open to grandfathered renewal.

  This is the pool a package dropdown draws from before a specific student is
  known. `package_available?/2` narrows it to what one student may actually
  buy.
  """
  def list_selectable_packages do
    Repo.all(
      from p in Package,
        where: p.active or p.grandfather_strategy == "past_purchasers",
        order_by: p.name
    )
  end

  @doc """
  Whether `package` is open to a student who has previously bought the
  packages in `purchased_package_ids`.

  An active package is open to anyone. An inactive one is open only under its
  grandfather strategy — today, only to a student who already holds it.
  """
  @spec package_available?(Package.t(), MapSet.t(integer()) | [integer()]) :: boolean()
  def package_available?(%Package{active: true}, _purchased_package_ids), do: true

  def package_available?(
        %Package{active: false, grandfather_strategy: "past_purchasers"} = package,
        purchased_package_ids
      ) do
    package.id in purchased_package_ids
  end

  def package_available?(%Package{active: false}, _purchased_package_ids), do: false

  def get_package!(id), do: Repo.get!(Package, id)

  def create_package(attrs) do
    %Package{} |> Package.changeset(attrs) |> Repo.insert()
  end

  def update_package(%Package{} = package, attrs) do
    package |> Package.changeset(attrs) |> Repo.update()
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
