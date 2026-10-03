defmodule Ganesha.Assistant.Tasks.ConfirmPayment do
  @moduledoc """
  `confirm_payment` (spec §3.1 #15): confirm a claimed payment that was
  recorded on the web, through `Ganesha.Sales.confirm_payment/2`, as the
  student and money cycle screens do.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{People, Sales}
  alias Ganesha.Assistant.Format
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
  def describe(parsed, locale) do
    %{
      title:
        "#{label(:title, locale)} #{parsed["student_name"]} #{Format.money(parsed["amount"])}",
      lines:
        Enum.reject(
          [
            line(:package, parsed["package_name"], locale),
            line(:method, method_name(parsed["method"], locale), locale),
            line(:paid_on, date_text(parsed["paid_on"], locale), locale)
          ],
          &is_nil/1
        ),
      changes: [
        {label(:state, locale), state_name(parsed["before_state"], locale),
         state_name("confirmed", locale)}
      ],
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

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

  defp label(:title, "en"), do: "Confirm payment"
  defp label(:title, _), do: "確認收款"
  defp label(:package, "en"), do: "Package"
  defp label(:package, _), do: "方案"
  defp label(:method, "en"), do: "Method"
  defp label(:method, _), do: "付款方式"
  defp label(:paid_on, "en"), do: "Paid on"
  defp label(:paid_on, _), do: "付款日"
  defp label(:state, "en"), do: "State"
  defp label(:state, _), do: "狀態"

  defp line(_key, value, _locale) when value in [nil, ""], do: nil
  defp line(key, value, "en"), do: "#{label(key, "en")}: #{value}"
  defp line(key, value, locale), do: "#{label(key, locale)}：#{value}"

  defp method_name(nil, _locale), do: nil
  defp method_name("line_pay", "en"), do: "LINE Pay"
  defp method_name("line_bank", "en"), do: "LINE Bank"
  defp method_name("cash", "en"), do: "Cash"
  defp method_name("other", "en"), do: "Other"
  defp method_name(method, "en"), do: method
  defp method_name(method, _locale), do: Fmt.method(method)

  defp date_text(nil, _locale), do: nil
  defp date_text(iso, "en"), do: iso

  defp date_text(iso, _locale) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Fmt.date(date)
      {:error, _} -> iso
    end
  end

  defp state_name("claimed", "en"), do: "Claimed"
  defp state_name("confirmed", "en"), do: "Confirmed"
  defp state_name("disputed", "en"), do: "Disputed"
  defp state_name("claimed", _), do: "待確認"
  defp state_name("confirmed", _), do: "已確認"
  defp state_name("disputed", _), do: "有疑義"
  defp state_name(other, _), do: other
end
