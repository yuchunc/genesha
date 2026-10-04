defmodule Ganesha.Assistant.Tasks.RecordPayment do
  @moduledoc """
  `record_payment` (spec §3.1 #14): a payment recorded and confirmed
  together when the teacher confirms the Draft. In the Teacher chat and the
  Group chat, where "2.Lulu（Line pay 1200元）" becomes one of these.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.{Assistant, Clock, People, Sales}
  alias Ganesha.Assistant.{Format, Summary}
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
  def summary(parsed, locale) do
    name = parsed["student_name"] || "?"
    amount = parsed["amount"]

    details =
      Summary.paren([Summary.method(parsed["method"], locale), short(parsed["paid_on"])], locale)

    head =
      if locale == "en",
        do: "Record #{Summary.money(amount)} from #{name}",
        else: "記錄 #{name} 付款 #{Summary.money(amount)}"

    head <> details <> owed(parsed["before_owed"], amount, locale)
  end

  defp owed(before, amount, locale) when is_integer(before) and is_integer(amount) do
    label = if locale == "en", do: "owes", else: "欠款"
    " — #{label} #{Summary.money(before)} → #{Summary.money(max(before - amount, 0))}"
  end

  defp owed(_before, _amount, _locale), do: ""

  defp short(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Fmt.short_date(date)
      {:error, _} -> nil
    end
  end

  defp short(_iso), do: nil

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
end
