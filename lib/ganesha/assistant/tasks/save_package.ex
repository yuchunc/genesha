defmodule Ganesha.Assistant.Tasks.SavePackage do
  @moduledoc """
  `save_package` (spec §3.1 #20): create or edit a catalog package through
  `Ganesha.Catalog.create_package/1` / `update_package/2`, as the settings
  screen does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Catalog}
  alias Ganesha.Assistant.Format
  alias Ganesha.Catalog.Package

  @create_keys ~w(name kind price_per_class included_makeups active grandfather_strategy)
  @update_keys ~w(package_id price_per_class included_makeups active grandfather_strategy)

  @impl true
  def name, do: "save_package"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Create a new package or edit an existing one on the price list. This only \
      proposes a Draft; the package is written when the teacher taps Confirm. \
      Omit package_id to create; pass package_id to edit price, makeup count, \
      active flag and grandfather strategy (name and kind are fixed after create).\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          package_id: %{type: "integer", description: "Omit to create a new package"},
          name: %{type: "string"},
          kind: %{type: "string", enum: Package.kinds()},
          price_per_class: %{type: "integer", description: "NT$ per class"},
          included_makeups: %{type: "integer"},
          active: %{type: "boolean"},
          grandfather_strategy: %{type: "string", enum: Package.grandfather_strategies()}
        },
        required: ["price_per_class", "included_makeups", "active", "grandfather_strategy"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    case input["package_id"] do
      nil -> propose_create(input)
      id when is_integer(id) -> propose_update(id, input)
      _other -> {:error, "package_id must be an integer or omitted to create"}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    case parsed["mode"] do
      "create" -> apply_create(parsed)
      "update" -> apply_update(parsed)
      _other -> {:error, :invalid_mode}
    end
  end

  @impl true
  def describe(parsed, locale) do
    case parsed["mode"] do
      "create" -> describe_create(parsed, locale)
      "update" -> describe_update(parsed, locale)
    end
  end

  defp propose_create(input) do
    attrs = take_create(input)

    with :ok <- validate_package(attrs),
         :ok <- require_create_fields(attrs) do
      parsed =
        Map.merge(attrs, %{
          "mode" => "create",
          "name" => String.trim(attrs["name"] || ""),
          "active" => bool_field(input, "active", true),
          "grandfather_strategy" => attrs["grandfather_strategy"] || "none"
        })

      {:ok, %{student_id: nil, parsed: parsed}}
    end
  end

  defp propose_update(id, input) do
    with {:ok, package} <- fetch_package(id) do
      attrs = take_update(input, package)

      with :ok <- validate_update(package, attrs) do
        parsed =
          Map.merge(attrs, %{
            "mode" => "update",
            "package_id" => package.id,
            "name" => package.name,
            "kind" => package.kind,
            "before_price_per_class" => package.price_per_class,
            "before_included_makeups" => package.included_makeups,
            "before_active" => package.active,
            "before_grandfather_strategy" => package.grandfather_strategy
          })

        {:ok, %{student_id: nil, parsed: parsed}}
      end
    end
  end

  defp apply_create(parsed) do
    attrs = Map.take(parsed, @create_keys)

    with :ok <- fields_unchanged?(parsed, attrs),
         {:ok, package} <- Catalog.create_package(normalize_package_attrs(attrs)) do
      {:ok, {"Ganesha.Catalog.Package", package.id}}
    end
  end

  defp apply_update(parsed) do
    attrs = Map.take(parsed, @update_keys)

    with {:ok, package} <- load_package(attrs["package_id"]),
         :ok <- package_unchanged?(package, parsed),
         {:ok, updated} <-
           Catalog.update_package(package, %{
             price_per_class: attrs["price_per_class"],
             included_makeups: attrs["included_makeups"],
             active: attrs["active"],
             grandfather_strategy: attrs["grandfather_strategy"]
           }) do
      {:ok, {"Ganesha.Catalog.Package", updated.id}}
    end
  end

  defp describe_create(parsed, locale) do
    %{
      title: "#{label(:create, locale)} #{parsed["name"]}",
      lines:
        Enum.reject(
          [
            line(:kind, kind_name(parsed["kind"], locale), locale),
            line(:price, Format.money(parsed["price_per_class"]), locale),
            line(:makeups, "#{parsed["included_makeups"]}", locale),
            line(:active, bool_name(parsed["active"], locale), locale),
            line(:grandfather, grandfather_name(parsed["grandfather_strategy"], locale), locale)
          ],
          &is_nil/1
        ),
      changes: [],
      web_path: "/settings"
    }
  end

  defp describe_update(parsed, locale) do
    %{
      title: "#{label(:edit, locale)} #{parsed["name"]}",
      lines: [line(:kind, kind_name(parsed["kind"], locale), locale)],
      changes:
        Enum.reject(
          [
            change(:price, parsed["before_price_per_class"], parsed["price_per_class"], locale),
            change(:makeups, parsed["before_included_makeups"], parsed["included_makeups"], locale),
            change(:active, parsed["before_active"], parsed["active"], locale),
            change(
              :grandfather,
              parsed["before_grandfather_strategy"],
              parsed["grandfather_strategy"],
              locale
            )
          ],
          &is_nil/1
        ),
      web_path: "/settings"
    }
  end

  defp fetch_package(id) do
    case Catalog.get_package(id) do
      nil -> {:error, "no package with id #{id}"}
      package -> {:ok, package}
    end
  end

  defp load_package(id) do
    case Catalog.get_package(id) do
      nil -> {:error, :not_found}
      package -> {:ok, package}
    end
  end

  defp take_create(input) do
    %{
      "name" => input["name"],
      "kind" => input["kind"],
      "price_per_class" => input["price_per_class"],
      "included_makeups" => input["included_makeups"],
      "active" => bool_field(input, "active", true),
      "grandfather_strategy" => input["grandfather_strategy"] || "none"
    }
  end

  defp take_update(input, package) do
    %{
      "price_per_class" => input["price_per_class"] || package.price_per_class,
      "included_makeups" => input["included_makeups"] || package.included_makeups,
      "active" => bool_field(input, "active", package.active),
      "grandfather_strategy" => input["grandfather_strategy"] || package.grandfather_strategy
    }
  end

  defp bool_field(input, key, default) do
    case Map.get(input, key) do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      nil -> default
      other -> other
    end
  end

  defp require_create_fields(%{"name" => name, "kind" => kind}) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed != "" and kind in Package.kinds(),
      do: :ok,
      else: {:error, "name and kind are required when creating a package"}
  end

  defp require_create_fields(_attrs),
    do: {:error, "name and kind are required when creating a package"}

  defp validate_package(attrs) do
    case %Package{} |> Package.changeset(normalize_package_attrs(attrs)) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, Assistant.format_changeset_errors(changeset)}
    end
  end

  defp validate_update(%Package{} = package, attrs) do
    case package
         |> Package.changeset(%{
           price_per_class: attrs["price_per_class"],
           included_makeups: attrs["included_makeups"],
           active: attrs["active"],
           grandfather_strategy: attrs["grandfather_strategy"]
         })
         |> Ecto.Changeset.apply_action(:validate) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, Assistant.format_changeset_errors(changeset)}
    end
  end

  defp normalize_package_attrs(attrs) do
    %{
      name: attrs["name"],
      kind: attrs["kind"],
      price_per_class: attrs["price_per_class"],
      included_makeups: attrs["included_makeups"],
      active: attrs["active"],
      grandfather_strategy: attrs["grandfather_strategy"]
    }
  end

  defp fields_unchanged?(parsed, attrs) do
    if Enum.all?(@create_keys, &(parsed[&1] == attrs[&1])), do: :ok, else: {:error, :package_changed}
  end

  defp package_unchanged?(package, parsed) do
    if package.price_per_class == parsed["before_price_per_class"] and
         package.included_makeups == parsed["before_included_makeups"] and
         package.active == parsed["before_active"] and
         package.grandfather_strategy == parsed["before_grandfather_strategy"],
       do: :ok,
       else: {:error, :package_changed}
  end

  defp label(:create, "en"), do: "New package"
  defp label(:create, _), do: "新增方案"
  defp label(:edit, "en"), do: "Edit package"
  defp label(:edit, _), do: "編輯方案"
  defp label(:kind, "en"), do: "Kind"
  defp label(:kind, _), do: "類型"
  defp label(:price, "en"), do: "Per class"
  defp label(:price, _), do: "每堂"
  defp label(:makeups, "en"), do: "Makeups included"
  defp label(:makeups, _), do: "補課次數"
  defp label(:active, "en"), do: "Open to new students"
  defp label(:active, _), do: "開放新學生"
  defp label(:grandfather, "en"), do: "When inactive"
  defp label(:grandfather, _), do: "停用後"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp change(:price, before, after_value, locale)
       when before != after_value,
       do: {label(:price, locale), Format.money(before), Format.money(after_value)}

  defp change(:makeups, before, after_value, locale) when before != after_value,
    do: {label(:makeups, locale), "#{before}", "#{after_value}"}

  defp change(:active, before, after_value, locale) when before != after_value,
    do: {label(:active, locale), bool_name(before, locale), bool_name(after_value, locale)}

  defp change(:grandfather, before, after_value, locale) when before != after_value,
    do:
      {label(:grandfather, locale), grandfather_name(before, locale),
       grandfather_name(after_value, locale)}

  defp change(_field, _before, _after, _locale), do: nil

  defp kind_name("monthly", "en"), do: "Monthly"
  defp kind_name("drop_in", "en"), do: "Drop-in"
  defp kind_name("trial", "en"), do: "Trial"
  defp kind_name("monthly", _), do: "月課程"
  defp kind_name("drop_in", _), do: "單堂"
  defp kind_name("trial", _), do: "體驗"
  defp kind_name(other, _), do: other

  defp bool_name(true, "en"), do: "Yes"
  defp bool_name(false, "en"), do: "No"
  defp bool_name(true, _), do: "是"
  defp bool_name(false, _), do: "否"
  defp bool_name(other, _), do: to_string(other)

  defp grandfather_name("none", "en"), do: "No renewals"
  defp grandfather_name("past_purchasers", "en"), do: "Past purchasers may renew"
  defp grandfather_name("none", _), do: "不可續購"
  defp grandfather_name("past_purchasers", _), do: "曾購買者可續購"
  defp grandfather_name(other, _), do: other
end
