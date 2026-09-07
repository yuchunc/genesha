defmodule GaneshaWeb.MoneyLive do
  @moduledoc """
  The finance landing page: this cycle's revenue and tax gauge, the two
  running lists that are never scoped to one month (未收款, 已過期補課額度),
  a trend across recent cycles, and a paginated way to reach any past one.

  Detail for a specific cycle — the full payment list, its breakdown by
  method, confirming a claim — lives one level down in `MoneyLive.Cycle`,
  reached by clicking the current-cycle card or a row in the history list.
  Splitting it this way keeps the landing page a glance, not a scroll.
  """
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Reporting, Roster}
  alias GaneshaWeb.Fmt

  @cycles_per_page 12
  @chart_months 6

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    page = parse_page(params["page"])
    current_month = Date.beginning_of_month(Clock.today())
    chart = chart_months(current_month)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:current_month, current_month)
     |> assign(:current_revenue, Reporting.revenue_for_month(current_month))
     |> assign(:tax, Reporting.tax_threshold_status(current_month))
     |> assign(:owing, Reporting.outstanding_by_student())
     |> assign(:expired_credits, Roster.expired_credits())
     |> assign(:chart_months, chart)
     |> assign(:chart_max, chart |> Enum.map(& &1.revenue) |> Enum.max(fn -> 0 end))
     |> assign(:cycles, previous_cycles(current_month, page))}
  end

  defp parse_page(nil), do: 0

  defp parse_page(page) do
    case Integer.parse(page) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  # The six most recent cycles, oldest first, for a left-to-right trend.
  defp chart_months(current_month) do
    for offset <- (@chart_months - 1)..0//-1 do
      month = Date.shift(current_month, month: -offset)
      %{month: month, revenue: Reporting.revenue_for_month(month)}
    end
  end

  # A page of history, strictly before the current cycle — which already has
  # its own card above and would be a redundant first row here. Only months
  # that have actually closed appear; there is no synthetic zero-revenue
  # filler for months before the studio had any data.
  defp previous_cycles(current_month, page) do
    Reporting.list_closed_months(
      before: current_month,
      limit: @cycles_per_page,
      offset: page * @cycles_per_page
    )
  end

  defp bar_height(_revenue, 0), do: 0
  defp bar_height(revenue, max), do: revenue / max * 100

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:money}>
      <.page_header title="款項" />

      <.link
        id="current-cycle"
        navigate={~p"/money/#{@current_month.year}/#{@current_month.month}"}
        class="block border-l-[3px] border-ink pl-4 transition-colors hover:bg-sunk"
      >
        <p class="text-sm text-ink-soft">{Fmt.month_title(@current_month)}</p>

        <p id="revenue" data-amount={@current_revenue}>
          <.money amount={@current_revenue} label="本期已確認" size="xl" tone="turmeric" />
        </p>

        <div class="mt-4">
          <div id="tax-gauge" class="relative h-4 bg-sunk">
            <div
              class={[
                "fills-across absolute inset-y-0 left-0 origin-left",
                @tax.warn? && "bg-sindoor",
                !@tax.warn? && "bg-turmeric"
              ]}
              style={"width: #{min(@tax.ratio, 1.0) * 100}%"}
            />
            <div class="absolute inset-x-0 bottom-0 h-px bg-rule-strong" />
          </div>

          <div class="mt-2 flex items-baseline justify-between gap-4">
            <p class="text-xs text-ink-soft">
              <%= if @tax.threshold - @tax.revenue > 0 do %>
                距起徵點還有
                <span class="font-display text-base text-ink">
                  {Fmt.amount(@tax.threshold - @tax.revenue)}
                </span>
              <% else %>
                已超過起徵點
                <span class="font-display text-base text-sindoor-ink">
                  {Fmt.amount(@tax.revenue - @tax.threshold)}
                </span>
              <% end %>
            </p>
            <p class="shrink-0 text-xs text-ink-faint">
              <span class="font-display">{Fmt.amount(@tax.threshold)}</span> 起徵點
            </p>
          </div>
        </div>
      </.link>

      <p
        :if={@tax.warn?}
        id="tax-warning"
        class="mt-3 border-l-[3px] border-sindoor bg-sindoor-lift py-3 pr-3 pl-4 text-sm text-ink"
      >
        本月已逼近勞務起徵點。單月超過就要辦理稅籍登記；逾期登記，會自當月一日起補徵。
      </p>

      <.section title="近月趨勢">
        <div id="revenue-chart" class="flex items-end justify-between gap-3 pt-2">
          <div :for={entry <- @chart_months} class="flex flex-1 flex-col items-center gap-2">
            <span class="font-display text-xs text-ink-faint">{Fmt.amount(entry.revenue)}</span>
            <div class="relative h-24 w-full max-w-8 border-t border-rule-strong bg-sunk">
              <div
                class={[
                  "fills-up absolute inset-x-0 bottom-0",
                  entry.month == @current_month && "bg-turmeric",
                  entry.month != @current_month && "bg-rule-strong"
                ]}
                style={"height: #{bar_height(entry.revenue, @chart_max)}%"}
              />
            </div>
            <span class="text-xs text-ink-faint">{entry.month.month}月</span>
          </div>
        </div>
      </.section>

      <.section title="未收款" count={length(@owing)}>
        <ul class="space-y-1">
          <li
            :for={row <- @owing}
            id={"owing-#{row.student.id}"}
            class="border-l-[3px] border-turmeric"
          >
            <.link
              navigate={~p"/students/#{row.student.id}"}
              class="flex min-h-11 items-center justify-between gap-4 py-1.5 pl-4 transition-colors hover:bg-sunk"
            >
              <span class="font-display text-lg text-ink">{row.student.display_name}</span>
              <.money amount={row.outstanding} tone="turmeric" class="shrink-0" />
            </.link>
          </li>
        </ul>

        <.empty :if={@owing == []} id="nothing-owed">本月款項都已收齊。</.empty>
      </.section>

      <.section
        :if={@expired_credits != []}
        id="expired-credits"
        title="已過期補課額度"
        count={length(@expired_credits)}
      >
        <ul class="space-y-1">
          <li
            :for={credit <- @expired_credits}
            class="flex min-h-11 items-center justify-between gap-4 border-l-[3px] border-sindoor py-1.5 pl-4"
          >
            <span class="font-display text-base text-ink">{credit.student.display_name}</span>
            <span class="shrink-0 text-xs text-sindoor-ink">
              <span class="font-display">{Fmt.short_date(credit.expires_on)}</span> 已過期
            </span>
          </li>
        </ul>
      </.section>

      <.section title="歷史款項">
        <:actions>
          <.button
            :if={@page > 0}
            variant="quiet"
            patch={~p"/money?#{[page: @page - 1]}"}
          >
            較近
          </.button>
          <.button variant="quiet" patch={~p"/money?#{[page: @page + 1]}"}>更早</.button>
        </:actions>

        <ul class="space-y-1">
          <li
            :for={cycle <- @cycles}
            id={"cycle-#{cycle.month.year}-#{cycle.month.month}"}
            class="border-l-[3px] border-rule"
          >
            <.link
              navigate={~p"/money/#{cycle.month.year}/#{cycle.month.month}"}
              class="flex min-h-11 items-center justify-between gap-4 py-1.5 pl-4 transition-colors hover:bg-sunk"
            >
              <span class="font-display text-base text-ink">{Fmt.month_title(cycle.month)}</span>
              <.money amount={cycle.revenue} size="sm" class="shrink-0" />
            </.link>
          </li>
        </ul>

        <.empty :if={@cycles == []} id="no-history">尚無歷史紀錄。</.empty>
      </.section>
    </Layouts.app>
    """
  end
end
