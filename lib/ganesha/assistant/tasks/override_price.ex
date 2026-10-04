defmodule Ganesha.Assistant.Tasks.OverridePrice do
  @moduledoc """
  `override_price` (spec §3.1 #16): set or clear a purchase's
  `custom_amount` through `Ganesha.Sales.update_purchase/2`, as the student
  screen's override form does.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Sales
  alias Ganesha.Assistant.Summary

  @apply_keys ~w(purchase_id custom_amount note)

  @impl true
  def name, do: "override_price"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Override what a student owes on a purchase (議價). This only proposes a Draft; \
      the purchase is updated when the teacher taps Confirm. Pass custom_amount to \
      set the agreed NT$ total, or omit it / pass null to clear the override back to \
      list price. Use purchase_id from the studio snapshot or student_summary.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          purchase_id: %{type: "integer"},
          custom_amount: %{
            type: ["integer", "null"],
            description: "NT$ owed instead of list price; null clears the override"
          },
          note: %{type: "string"}
        },
        required: ["purchase_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, purchase} <- fetch_purchase(input["purchase_id"]),
         :ok <- check_amount(input["custom_amount"]) do
      student = purchase.student
      before_payable = Sales.payable(purchase)
      after_payable = after_payable(purchase, input["custom_amount"])

      parsed = %{
        "purchase_id" => purchase.id,
        "custom_amount" => blank_amount(input["custom_amount"]),
        # An omitted note keeps the purchase's note, as the web form's prefill does.
        "note" => input["note"] || purchase.note,
        "before_note" => purchase.note,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "package_name" => purchase.package.name,
        "list_price" => purchase.list_price,
        "before_custom_amount" => purchase.custom_amount,
        "before_payable" => before_payable,
        "after_payable" => after_payable
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, _confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, purchase} <- load_purchase(attrs["purchase_id"]),
         :ok <- same_custom_amount(purchase, parsed["before_custom_amount"]),
         :ok <- same_note(purchase, parsed["before_note"]),
         {:ok, updated} <-
           Sales.update_purchase(purchase, %{
             custom_amount: attrs["custom_amount"],
             note: attrs["note"]
           }) do
      {:ok, {"Ganesha.Sales.Purchase", updated.id}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    package = parsed["package_name"]
    list = Summary.money(parsed["list_price"])
    was = Summary.money(parsed["before_payable"])

    case {parsed["custom_amount"], locale} do
      {nil, "en"} -> "Charge #{name} the list price #{list} for #{package}"
      {nil, _} -> "#{name} 的#{package}改回原價 #{list}"
      {amount, "en"} -> "Charge #{name} #{Summary.money(amount)} for #{package} (was #{was})"
      {amount, _} -> "#{name} 的#{package}改收 #{Summary.money(amount)}（原本 #{was}）"
    end
  end

  defp fetch_purchase(id) when is_integer(id) do
    case Sales.get_purchase(id) do
      nil -> {:error, "no purchase with id #{id}"}
      purchase -> {:ok, purchase}
    end
  end

  defp fetch_purchase(_id), do: {:error, "purchase_id must be an integer"}

  defp load_purchase(id) when is_integer(id) do
    case Sales.get_purchase(id) do
      nil -> {:error, :not_found}
      purchase -> {:ok, purchase}
    end
  end

  defp load_purchase(_id), do: {:error, :not_found}

  defp check_amount(nil), do: :ok
  defp check_amount(amount) when is_integer(amount) and amount >= 0, do: :ok

  defp check_amount(_amount),
    do: {:error, "custom_amount must be a whole NT$ amount of 0 or more, or null to clear"}

  defp blank_amount(nil), do: nil
  defp blank_amount(amount), do: amount

  defp after_payable(purchase, nil), do: purchase.list_price
  defp after_payable(_purchase, amount) when is_integer(amount), do: amount

  defp same_custom_amount(%{custom_amount: current}, expected) do
    if current == expected, do: :ok, else: {:error, :purchase_changed}
  end

  defp same_note(%{note: current}, expected) do
    if current == expected, do: :ok, else: {:error, :purchase_changed}
  end
end
