defmodule Ganesha.Assistant.Tasks.RecordPayment do
  @moduledoc """
  `record_payment` (spec §3.1 #14): a payment recorded and confirmed
  together when the teacher confirms the Draft. In the Teacher chat and the
  Group chat, where "2.Lulu（Line pay 1200元）" becomes one of these.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Clock, People, Sales}
  alias Ganesha.Assistant.Format
  alias Ganesha.Sales.Payment
  alias GaneshaWeb.Fmt

  # What `propose/2` writes for `apply/2`; every other key in `parsed` is display.
  @apply_keys ~w(purchase_id amount method paid_on reported_last5 note)

  @impl true
  def name, do: "record_payment"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Record money a student paid. This only proposes a Draft; the payment is recorded \
      and confirmed when the teacher taps Confirm. Use ids from the studio snapshot. Omit \
      purchase_id when the student owes on exactly one purchase.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          purchase_id: %{type: "integer", description: "The purchase this money pays for"},
          amount: %{type: "integer", description: "NT$, whole dollars"},
          method: %{type: "string", enum: Payment.methods()},
          paid_on: %{type: "string", description: "ISO 8601 date; defaults to today"},
          reported_last5: %{
            type: "string",
            description: "Last five digits of the sender's account, if given"
          },
          note: %{type: "string"}
        },
        required: ["student_id", "amount", "method"]
      }
    }
  end

  @impl true
  def propose(input, ctx) do
    with {:ok, student} <- fetch_student(input["student_id"]),
         {:ok, purchase, owed} <- pick_purchase(student, input["purchase_id"]),
         {:ok, paid_on} <- parse_date(input["paid_on"], ctx.today),
         {:ok, payment} <-
           validate_payment(%{
             "purchase_id" => purchase.id,
             "amount" => input["amount"],
             "method" => input["method"],
             "paid_on" => paid_on,
             "reported_last5" => input["reported_last5"],
             "note" => input["note"]
           }) do
      parsed = %{
        "purchase_id" => payment.purchase_id,
        "amount" => payment.amount,
        "method" => payment.method,
        "paid_on" => Date.to_iso8601(payment.paid_on),
        "reported_last5" => payment.reported_last5,
        "note" => payment.note,
        "student_id" => student.id,
        "student_name" => student.display_name,
        "package_name" => purchase.package.name,
        "before_owed" => owed
      }

      {:ok, %{student_id: student.id, parsed: parsed}}
    end
  end

  @impl true
  def apply(parsed, confirmed_by) do
    today = Date.to_iso8601(Clock.today())

    # Drafts migrated from the old `payment` kind may lack `paid_on`.
    attrs =
      parsed
      |> Map.take(@apply_keys)
      |> Map.update("paid_on", today, &(&1 || today))
      |> Map.put("source", "line_draft")

    with :ok <- require_purchase(attrs),
         {:ok, payment} <- Sales.record_payment(attrs),
         {:ok, payment} <- Sales.confirm_payment(payment, confirmed_by) do
      {:ok, {"Ganesha.Sales.Payment", payment.id}}
    end
  end

  @impl true
  def describe(parsed, locale) do
    amount = parsed["amount"]

    %{
      title: "#{label(:title, locale)} #{parsed["student_name"] || "?"} #{Format.money(amount)}",
      lines:
        Enum.reject(
          [
            line(:package, parsed["package_name"], locale),
            line(:method, method_name(parsed["method"], locale), locale),
            line(:paid_on, date_text(parsed["paid_on"], locale), locale),
            line(:last5, parsed["reported_last5"], locale),
            line(:note, parsed["note"], locale)
          ],
          &is_nil/1
        ),
      changes: owed_change(parsed["before_owed"], amount, locale),
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

  defp fetch_student(id) when is_integer(id) do
    case People.get_student(id) do
      nil -> {:error, "no student with id #{id}; use a student id from the snapshot"}
      student -> {:ok, student}
    end
  end

  defp fetch_student(_id), do: {:error, "student_id must be a student id from the snapshot"}

  defp pick_purchase(student, purchase_id) do
    owing =
      student.id
      |> Sales.list_purchases_for_student()
      |> Enum.map(&{&1, owed(&1)})

    pick(owing, purchase_id, student)
  end

  defp pick(owing, nil, student) do
    case Enum.filter(owing, fn {_purchase, owed} -> owed > 0 end) do
      [{purchase, owed}] ->
        {:ok, purchase, owed}

      [] ->
        {:error,
         "#{student.display_name} owes nothing on any purchase; " <>
           "ask the teacher which purchase this money is for"}

      several ->
        {:error,
         "#{student.display_name} owes on several purchases: " <>
           Enum.map_join(several, "; ", &purchase_text/1) <>
           ". Pass purchase_id, or ask the teacher which one."}
    end
  end

  defp pick(owing, purchase_id, student) when is_integer(purchase_id) do
    case Enum.find(owing, fn {purchase, _owed} -> purchase.id == purchase_id end) do
      {purchase, owed} -> {:ok, purchase, owed}
      nil -> {:error, "purchase #{purchase_id} is not one of #{student.display_name}'s purchases"}
    end
  end

  defp pick(_owing, _purchase_id, _student), do: {:error, "purchase_id must be an integer"}

  defp owed(purchase), do: Sales.payable(purchase) - Sales.confirmed_paid(purchase.id)

  defp purchase_text({purchase, owed}) do
    slot = if purchase.slot, do: " #{purchase.slot.label}", else: ""
    "purchase #{purchase.id} #{purchase.package.name}#{slot} (owes #{Format.money(owed)})"
  end

  defp parse_date(nil, today), do: {:ok, today}

  defp parse_date(text, _today) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "paid_on must be an ISO 8601 date like 2026-10-02"}
    end
  end

  defp parse_date(_value, _today),
    do: {:error, "paid_on must be an ISO 8601 date like 2026-10-02"}

  defp validate_payment(attrs) do
    case %Payment{} |> Payment.changeset(attrs) |> Ecto.Changeset.apply_action(:validate) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, changeset} ->
        {:error, "invalid payment: " <> Assistant.format_changeset_errors(changeset)}
    end
  end

  defp require_purchase(%{"purchase_id" => id}) when is_integer(id), do: :ok
  defp require_purchase(_attrs), do: {:error, :missing_purchase_id}

  defp label(:title, "en"), do: "Payment"
  defp label(:title, _), do: "收款"
  defp label(:package, "en"), do: "Package"
  defp label(:package, _), do: "方案"
  defp label(:method, "en"), do: "Method"
  defp label(:method, _), do: "付款方式"
  defp label(:paid_on, "en"), do: "Paid on"
  defp label(:paid_on, _), do: "付款日"
  defp label(:last5, "en"), do: "Last 5 digits"
  defp label(:last5, _), do: "末五碼"
  defp label(:note, "en"), do: "Note"
  defp label(:note, _), do: "備註"
  defp label(:owed, "en"), do: "Owed"
  defp label(:owed, _), do: "尚欠"

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

  defp owed_change(before, amount, locale) when is_integer(before) and is_integer(amount),
    do: [{label(:owed, locale), Format.money(before), Format.money(before - amount)}]

  defp owed_change(_before, _amount, _locale), do: []
end
