defmodule GaneshaWeb.StudentLive.Show do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, People, Reporting, Repo, Roster, Sales}
  alias Ganesha.Sales.Payment

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, socket |> assign(:student, People.get_student!(id)) |> load()}
  end

  defp load(socket) do
    student = socket.assigns.student
    purchases = Sales.list_purchases_for_student(student.id)

    payments =
      Map.new(purchases, fn purchase ->
        rows =
          purchase.id
          |> Sales.list_payments_for_purchase()
          |> Enum.map(&%{payment: &1, suspicious?: Sales.suspicious_last5?(&1)})

        {purchase.id, rows}
      end)

    socket
    |> assign(:purchases, purchases)
    |> assign(:payments, payments)
    |> assign(:outstanding, Reporting.outstanding_for_student(student.id))
    |> assign(:credits, Roster.available_credits(student.id, Clock.today()))
  end

  @impl true
  def handle_event("confirm_payment", %{"id" => id}, socket) do
    payment = Repo.get!(Payment, id)
    # The confirmer is the logged-in teacher: confirmation is a human assertion
    # that the money arrived, and the schema records who made it.
    {:ok, _} = Sales.confirm_payment(payment, socket.assigns.current_scope.user.email)

    {:noreply, socket |> put_flash(:info, "已確認收款") |> load()}
  end

  def handle_event("record_payment", %{"purchase-id" => id} = params, socket) do
    case Sales.record_payment(%{
           purchase_id: id,
           amount: params["amount"],
           method: params["method"],
           paid_on: Clock.today(),
           reported_last5: blank_to_nil(params["reported_last5"]),
           source: "manual"
         }) do
      {:ok, _payment} ->
        {:noreply,
         socket
         |> put_flash(:info, "已記錄，待確認入帳")
         |> load()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "金額或方式不正確")}
    end
  end

  def handle_event("override", %{"purchase-id" => id} = params, socket) do
    purchase = Sales.get_purchase!(id)

    attrs = %{
      custom_amount: blank_to_nil(params["custom_amount"]),
      note: blank_to_nil(params["note"])
    }

    {:ok, _} = Sales.update_purchase(purchase, attrs)

    {:noreply, socket |> put_flash(:info, "已更新金額") |> load()}
  end

  # An empty field means "no override", which must become NULL rather than 0.
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp confirmed_paid(payment_rows) do
    payment_rows
    |> Enum.map(& &1.payment)
    |> Enum.filter(&(&1.state == "confirmed"))
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@student.display_name}</h1>

        <p id="outstanding" data-amount={@outstanding} class="mt-1 text-sm text-zinc-500">
          未收：NT$ {@outstanding}
        </p>

        <section
          :if={@credits != []}
          class="mt-4 rounded-2xl border border-purple-200 p-4 dark:border-purple-900"
        >
          <h2 class="text-sm font-medium">可用補課額度：{length(@credits)}</h2>
          <ul class="mt-2 space-y-1 text-xs text-zinc-500">
            <li :for={credit <- @credits}>
              {credit.source} ·
              <%= if credit.expires_on do %>
                至 {credit.expires_on}
              <% else %>
                無期限
              <% end %>
            </li>
          </ul>
        </section>

        <section
          :for={purchase <- @purchases}
          id={"purchase-#{purchase.id}"}
          class="mt-4 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <header class="flex items-baseline justify-between gap-2">
            <h2 class="font-medium">{purchase.package.name}</h2>
            <span class="font-mono text-sm">NT$ {Sales.payable(purchase)}</span>
          </header>

          <p :if={purchase.custom_amount} class="mt-1 text-xs text-zinc-500">
            原價 {purchase.list_price}<span :if={purchase.note}> · {purchase.note}</span>
          </p>

          <form
            id={"override-form-#{purchase.id}"}
            phx-submit="override"
            class="mt-3 flex flex-wrap gap-2"
          >
            <input type="hidden" name="purchase-id" value={purchase.id} />
            <input
              type="number"
              name="custom_amount"
              value={purchase.custom_amount}
              placeholder="自訂金額"
              class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="text"
              name="note"
              value={purchase.note}
              placeholder="備註"
              class="min-h-[44px] w-32 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              儲存
            </button>
          </form>

          <form
            id={"payment-form-#{purchase.id}"}
            phx-submit="record_payment"
            class="mt-3 flex flex-wrap gap-2"
          >
            <input type="hidden" name="purchase-id" value={purchase.id} />
            <input
              type="number"
              name="amount"
              placeholder="金額"
              value={Sales.payable(purchase) - confirmed_paid(@payments[purchase.id] || [])}
              class="min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <select
              name="method"
              class="min-h-[44px] rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            >
              <option value="line_pay">Line Pay</option>
              <option value="line_bank">LINE Bank</option>
              <option value="cash">現金</option>
              <option value="other">其他</option>
            </select>
            <input
              type="text"
              name="reported_last5"
              placeholder="帳後五碼"
              inputmode="numeric"
              class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              記錄
            </button>
          </form>

          <ul class="mt-3 space-y-2">
            <li
              :for={%{payment: payment, suspicious?: suspicious?} <- @payments[purchase.id] || []}
              data-suspicious={to_string(suspicious?)}
              class="flex items-center justify-between gap-2 text-sm"
            >
              <span>
                NT$ {payment.amount} · {payment.method}
                <span :if={payment.reported_last5} class="text-zinc-400">
                  ({payment.reported_last5})
                </span>
                <span :if={suspicious?} class="text-amber-600">重複？</span>
              </span>

              <button
                :if={payment.state == "claimed"}
                id={"confirm-payment-#{payment.id}"}
                phx-click="confirm_payment"
                phx-value-id={payment.id}
                class="min-h-[44px] rounded-lg bg-emerald-600 px-3 text-xs text-white"
              >
                確認入帳
              </button>
              <span :if={payment.state == "confirmed"} class="text-xs text-emerald-600">已確認</span>
              <span :if={payment.state == "disputed"} class="text-xs text-red-600">有問題</span>
            </li>
          </ul>
        </section>
      </div>

      <Layouts.bottom_nav active={:students} />
    </Layouts.app>
    """
  end
end
