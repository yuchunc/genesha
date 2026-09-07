defmodule GaneshaWeb.MoneyLive.Cycle do
  @moduledoc """
  One billing cycle's full picture: every payment recorded against it, broken
  down by method, and the confirm action — reached by clicking a cycle from
  `MoneyLive`, the finance landing page.
  """
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Reporting, Repo, Sales}
  alias Ganesha.Sales.Payment
  alias GaneshaWeb.Fmt

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_month(params) |> load()}
  end

  defp assign_month(socket, %{"year" => year, "month" => month}) do
    with {y, ""} <- Integer.parse(year),
         {m, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(y, m, 1) do
      assign(socket, :month, date)
    else
      _ -> assign_month(socket, %{})
    end
  end

  defp assign_month(socket, _params) do
    assign(socket, :month, Date.beginning_of_month(Clock.today()))
  end

  defp load(socket) do
    month = socket.assigns.month
    summary = Reporting.cycle_summary(month)

    socket
    |> assign(:revenue, summary.revenue)
    |> assign(:by_method, Enum.reject(summary.by_method, &match?({_, 0}, &1)))
    |> assign(:payments, payments_with_flags(month))
  end

  defp payments_with_flags(month) do
    month
    |> Reporting.payments_for_month()
    |> Enum.map(&%{payment: &1, suspicious?: Sales.suspicious_last5?(&1)})
  end

  @impl true
  def handle_event("confirm_payment", %{"id" => id}, socket) do
    payment = Repo.get!(Payment, id)
    # The confirmer is the logged-in teacher: confirmation is a human
    # assertion that the money arrived, and the schema records who made it.
    {:ok, _} = Sales.confirm_payment(payment, socket.assigns.current_scope.user.email)

    {:noreply, socket |> put_flash(:info, "已確認收款") |> load()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:money} back={~p"/money"}>
      <.page_header title={Fmt.month_title(@month)}>
        <:actions>
          <.button variant="quiet" navigate={month_path(@month, -1)}>
            {month_label(@month, -1)}
          </.button>
          <.button variant="quiet" navigate={month_path(@month, 1)}>
            {month_label(@month, 1)}
          </.button>
        </:actions>
      </.page_header>

      <p id="cycle-revenue" data-amount={@revenue}>
        <.money amount={@revenue} label="本期已確認收入" size="xl" tone="turmeric" />
      </p>

      <.section :if={@by_method != []} title="收款方式">
        <ul class="space-y-1">
          <li
            :for={{method, amount} <- @by_method}
            class="flex items-baseline justify-between gap-4 border-l-[3px] border-rule pl-4"
          >
            <span class="text-sm text-ink-soft">{Fmt.method(method)}</span>
            <.money amount={amount} size="sm" class="shrink-0" />
          </li>
        </ul>
      </.section>

      <.section title="本期收款" count={length(@payments)}>
        <ul :if={@payments != []} class="space-y-2">
          <li
            :for={%{payment: payment, suspicious?: suspicious?} <- @payments}
            id={"payment-#{payment.id}"}
            data-suspicious={to_string(suspicious?)}
            class={["border-l-[3px] py-2 pl-4", payment_rule(payment.state)]}
          >
            <div class="flex items-baseline justify-between gap-4">
              <.link navigate={~p"/students/#{payment.purchase.student_id}"} class="min-w-0 flex-1">
                <span class="font-display text-base text-ink">
                  {payment.purchase.student.display_name}
                </span>
                <span class="block text-xs text-ink-faint">
                  {Fmt.method(payment.method)} ·
                  <span class="font-display">{Fmt.short_date(payment.paid_on)}</span>
                </span>
              </.link>
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

        <.empty :if={@payments == []} id="no-payments">本期還沒有收款紀錄。</.empty>
      </.section>
    </Layouts.app>
    """
  end

  defp month_path(%Date{} = month, delta) do
    target = sibling_month(month, delta)
    ~p"/money/#{target.year}/#{target.month}"
  end

  defp month_label(%Date{} = month, delta), do: "#{sibling_month(month, delta).month}月"

  defp sibling_month(%Date{} = month, delta), do: Date.shift(month, month: delta)

  defp payment_rule("confirmed"), do: "border-celadon"
  defp payment_rule("disputed"), do: "border-sindoor"
  defp payment_rule(_state), do: "border-turmeric"

  defp payment_tone("confirmed"), do: "celadon"
  defp payment_tone("claimed"), do: "turmeric"
  defp payment_tone("disputed"), do: "sindoor"
  defp payment_tone(_state), do: "quiet"
end
