defmodule Ganesha.Assistant.Tasks.ConfirmPayment do
  @moduledoc """
  `confirm_payment` (spec §3.1 #15): confirm a claimed payment that was
  recorded on the web, through `Ganesha.Sales.confirm_payment/2`, as the
  student and money cycle screens do.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Sales}
  alias Ganesha.Assistant.Summary
  alias GaneshaWeb.Fmt

  @apply_keys ~w(payment_id)

  @impl true
  def name, do: "confirm_payment"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Confirm that a payment the teacher recorded on the web has actually arrived. \
      This only proposes a Draft; the payment is confirmed when she taps Confirm. \
      Use payment_id from the studio snapshot or from student_summary. Only claimed \
      payments can be confirmed.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          payment_id: %{type: "integer", description: "A payment in state claimed"}
        },
        required: ["payment_id"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, payment} <- fetch_payment(input["payment_id"]),
         :ok <- check_claimed(payment),
         purchase <- Sales.get_purchase!(payment.purchase_id),
         student <- People.get_student!(purchase.student_id) do
      parsed = %{
        "payment_id" => payment.id,
        "purchase_id" => purchase.id,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "package_name" => purchase.package.name,
        "amount" => payment.amount,
        "method" => payment.method,
        "paid_on" => Date.to_iso8601(payment.paid_on),
        "before_state" => payment.state
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, confirmed_by) do
    attrs = Map.take(parsed, @apply_keys)

    with {:ok, payment} <- load_payment(attrs["payment_id"]),
         :ok <- still_claimed(payment),
         {:ok, confirmed} <- Sales.confirm_payment(payment, confirmed_by) do
      {:ok, {"Ganesha.Sales.Payment", confirmed.id}}
    end
  end

  @impl true
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    amount = Summary.money(parsed["amount"])

    details =
      Summary.paren([Summary.method(parsed["method"], locale), short(parsed["paid_on"])], locale)

    if locale == "en",
      do: "Confirm #{amount} received from #{name}" <> details,
      else: "確認收到 #{name} 的 #{amount}" <> details
  end

  defp short(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Fmt.short_date(date)
      {:error, _} -> nil
    end
  end

  defp short(_iso), do: nil

  defp fetch_payment(id) when is_integer(id) do
    case Sales.get_payment(id) do
      nil -> {:error, "no payment with id #{id}"}
      payment -> {:ok, payment}
    end
  end

  defp fetch_payment(_id), do: {:error, "payment_id must be an integer"}

  defp load_payment(id) when is_integer(id) do
    case Sales.get_payment(id) do
      nil -> {:error, :not_found}
      payment -> {:ok, payment}
    end
  end

  defp load_payment(_id), do: {:error, :not_found}

  defp check_claimed(%{state: "claimed"}), do: :ok
  defp check_claimed(%{state: state}), do: {:error, "payment is already #{state}, not claimed"}

  defp still_claimed(%{state: "claimed"}), do: :ok
  defp still_claimed(_payment), do: {:error, :payment_not_claimed}
end
