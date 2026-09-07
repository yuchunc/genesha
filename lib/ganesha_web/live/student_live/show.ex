defmodule GaneshaWeb.StudentLive.Show do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, People, Reporting, Repo, Roster, Sales}
  alias Ganesha.Sales.Payment
  alias GaneshaWeb.Fmt

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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:students}
      back={~p"/students"}
    >
      <.page_header title={@student.display_name} />

      <p id="outstanding" data-amount={@outstanding}>
        <.money
          amount={@outstanding}
          size="lg"
          tone={if @outstanding > 0, do: "turmeric", else: "celadon"}
          label={if @outstanding > 0, do: "未收", else: "已收齊"}
        />
      </p>

      <.section :if={@credits != []} id="credits" title="補課額度" count={length(@credits)}>
        <ul class="space-y-1">
          <.credit_row :for={credit <- @credits} credit={credit} />
        </ul>
      </.section>

      <.section title="購買與收款" count={length(@purchases)}>
        <.empty :if={@purchases == []}>這位學生還沒有購買紀錄。</.empty>

        <.purchase_group
          :for={purchase <- @purchases}
          purchase={purchase}
          payment_rows={@payments[purchase.id] || []}
        />
      </.section>
    </Layouts.app>
    """
  end

  attr :credit, :map, required: true

  defp credit_row(assigns) do
    ~H"""
    <li class="flex min-h-11 items-center justify-between gap-4 border-l-[3px] border-turmeric py-1.5 pl-4">
      <span class="text-sm text-ink">{credit_source(@credit.source)}</span>
      <span class="shrink-0 font-display text-xs text-ink-faint">
        {if @credit.expires_on, do: Fmt.short_date(@credit.expires_on), else: "無期限"}
      </span>
    </li>
    """
  end

  attr :purchase, :map, required: true
  attr :payment_rows, :list, required: true

  defp purchase_group(assigns) do
    payable = Sales.payable(assigns.purchase)
    paid = confirmed_paid(assigns.payment_rows)

    assigns = assign(assigns, payable: payable, paid: paid, due: payable - paid)

    ~H"""
    <section
      id={"purchase-#{@purchase.id}"}
      class={[
        "mt-5 border-l-[3px] pl-4",
        @due > 0 && "border-turmeric",
        @due <= 0 && "border-celadon"
      ]}
    >
      <div class="flex items-baseline justify-between gap-4">
        <h3 class="font-display text-lg text-ink">{@purchase.package.name}</h3>
        <.money
          amount={@payable}
          tone={if @due > 0, do: "turmeric", else: "celadon"}
          class="shrink-0"
        />
      </div>

      <p :if={@purchase.slot} class="mt-1 flex items-center gap-2 text-xs text-ink-soft">
        <.seal weekday={@purchase.slot.weekday} size="sm" />
        <span>
          {Fmt.slot_title(@purchase.slot.label)}
          <span class="font-display">
            {Fmt.time_range(@purchase.slot.start_time, @purchase.slot.end_time)}
          </span>
        </span>
      </p>

      <p :if={@purchase.custom_amount} class="mt-1 text-xs text-ink-soft">
        原價
        <span class="font-display text-ink-faint line-through">
          {Fmt.amount(@purchase.list_price)}
        </span>
        ，已議定為此金額<span :if={@purchase.note}>：{@purchase.note}</span>
      </p>

      <p class="mt-1 text-xs text-ink-faint">
        已收 <span class="font-display">{Fmt.amount(@paid)}</span>
        <span :if={@due > 0}>
          · 未收 <span class="font-display text-turmeric-ink">{Fmt.amount(@due)}</span>
        </span>
      </p>

      <ul class="mt-3 space-y-2">
        <li
          :for={%{payment: payment, suspicious?: suspicious?} <- @payment_rows}
          data-suspicious={to_string(suspicious?)}
          class={["border-l-[3px] py-2 pl-4", payment_rule(payment.state)]}
        >
          <div class="flex items-baseline justify-between gap-4">
            <span class="text-sm text-ink-soft">
              {Fmt.method(payment.method)}
              <span class="font-display">{Fmt.short_date(payment.paid_on)}</span>
            </span>
            <.money
              amount={payment.amount}
              size="sm"
              tone={if payment.state == "confirmed", do: "celadon", else: "ink"}
              class="shrink-0"
            />
          </div>

          <div class="mt-1 flex flex-wrap items-center justify-between gap-3">
            <.pill tone={payment_tone(payment.state)}>{Fmt.payment_state(payment.state)}</.pill>

            <.button
              :if={payment.state == "claimed"}
              id={"confirm-payment-#{payment.id}"}
              variant="accent"
              phx-click="confirm_payment"
              phx-value-id={payment.id}
            >
              確認收到
            </.button>

            <span :if={payment.state == "confirmed"} class="truncate text-xs text-ink-faint">
              {payment.confirmed_by} 已確認
            </span>
          </div>

          <p :if={suspicious?} class="mt-1 text-xs text-sindoor-ink">
            帳後五碼 {payment.reported_last5} 和另一筆款項重複，確認收到之前先對一次帳。
          </p>
        </li>
      </ul>

      <details class="mt-3 border-t border-rule">
        <summary class="flex min-h-11 cursor-pointer list-none items-center text-sm text-ink-soft [&::-webkit-details-marker]:hidden">
          調整金額
        </summary>
        <form id={"override-form-#{@purchase.id}"} phx-submit="override" class="mb-3 space-y-3">
          <input type="hidden" name="purchase-id" value={@purchase.id} />
          <.input
            type="number"
            name="custom_amount"
            value={@purchase.custom_amount}
            label="議定金額"
            placeholder="留空即照原價"
          />
          <.input
            type="text"
            name="note"
            value={@purchase.note}
            label="備註"
            placeholder="為什麼調整"
          />
          <.button variant="primary">儲存調整</.button>
        </form>
      </details>

      <details class="border-t border-rule">
        <summary class="flex min-h-11 cursor-pointer list-none items-center text-sm text-ink-soft [&::-webkit-details-marker]:hidden">
          記錄收款
        </summary>
        <form
          id={"payment-form-#{@purchase.id}"}
          phx-submit="record_payment"
          class="mb-3 space-y-3"
        >
          <input type="hidden" name="purchase-id" value={@purchase.id} />
          <.input type="number" name="amount" value={@due} label="金額" />
          <.input
            type="select"
            name="method"
            value="line_pay"
            label="方式"
            options={[
              {"Line Pay", "line_pay"},
              {"LINE Bank", "line_bank"},
              {"現金", "cash"},
              {"其他", "other"}
            ]}
          />
          <.input
            type="text"
            name="reported_last5"
            value=""
            label="帳後五碼"
            inputmode="numeric"
            placeholder="轉帳末五碼"
          />
          <.button variant="accent">記錄收款</.button>
        </form>
      </details>
    </section>
    """
  end

  defp credit_source("package"), do: "課程附帶"
  defp credit_source("cancellation"), do: "停課補償"
  defp credit_source(other), do: other

  defp payment_tone("confirmed"), do: "celadon"
  defp payment_tone("claimed"), do: "turmeric"
  defp payment_tone("disputed"), do: "sindoor"
  defp payment_tone(_state), do: "quiet"

  defp payment_rule("confirmed"), do: "border-celadon"
  defp payment_rule("claimed"), do: "border-turmeric"
  defp payment_rule("disputed"), do: "border-sindoor"
  defp payment_rule(_state), do: "border-rule"
end
