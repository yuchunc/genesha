defmodule GaneshaWeb.MoneyLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Reporting, Roster}

  @impl true
  def mount(_params, _session, socket) do
    month = Date.beginning_of_month(Clock.today())

    {:ok,
     socket
     |> assign(:month, month)
     |> assign(:owing, Reporting.outstanding_by_student())
     |> assign(:revenue, Reporting.revenue_for_month(month))
     |> assign(:tax, Reporting.tax_threshold_status(month))
     |> assign(:expired_credits, Roster.expired_credits())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">收款</h1>

        <section class="mt-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800">
          <p id="revenue" data-amount={@revenue} class="text-2xl font-semibold tabular-nums">
            NT$ {@revenue}
          </p>
          <p class="text-xs text-zinc-500">{@month.year} 年 {@month.month} 月已確認收入</p>

          <div
            id="tax-gauge"
            class="mt-3 h-2 overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800"
          >
            <div
              class={[
                "h-full rounded-full transition-all",
                @tax.warn? && "bg-amber-500",
                !@tax.warn? && "bg-emerald-500"
              ]}
              style={"width: #{min(@tax.ratio, 1.0) * 100}%"}
            />
          </div>

          <p class="mt-1 text-xs text-zinc-500">營業稅起徵點 NT$ {@tax.threshold} / 月（勞務）</p>

          <p
            :if={@tax.warn?}
            id="tax-warning"
            class="mt-2 rounded-lg bg-amber-50 p-2 text-xs text-amber-800 dark:bg-amber-950 dark:text-amber-200"
          >
            本月接近起徵點。超過當月即須辦理稅籍登記，逾期會自當月一日起補徵。
          </p>
        </section>

        <section class="mt-4">
          <h2 class="text-sm font-medium text-zinc-500">未收款</h2>
          <ul class="mt-2 space-y-2">
            <li
              :for={row <- @owing}
              id={"owing-#{row.student.id}"}
              class="flex min-h-[56px] items-center justify-between rounded-xl border border-zinc-200 px-4 dark:border-zinc-800"
            >
              <.link navigate={~p"/students/#{row.student.id}"}>{row.student.display_name}</.link>
              <span class="font-mono text-sm">NT$ {row.outstanding}</span>
            </li>
            <li :if={@owing == []} id="nothing-owed" class="text-sm text-zinc-400">全部收齊</li>
          </ul>
        </section>

        <section :if={@expired_credits != []} class="mt-4">
          <h2 class="text-sm font-medium text-zinc-500">已過期補課額度</h2>
          <ul class="mt-2 space-y-1 text-xs text-zinc-500">
            <li :for={credit <- @expired_credits}>
              {credit.student.display_name} · 到期 {credit.expires_on}
            </li>
          </ul>
        </section>
      </div>

      <Layouts.bottom_nav active={:money} />
    </Layouts.app>
    """
  end
end
