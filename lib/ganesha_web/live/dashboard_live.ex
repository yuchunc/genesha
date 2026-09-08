defmodule GaneshaWeb.DashboardLive do
  @moduledoc """
  Three views of the same studio, each answering a different question.

  * `a` 今日 — what do I need to do in the next hour?
  * `b` 四軌 — how is this month shaped?
  * `c` 帳   — who owes me, and am I near the tax line?

  They are variations in information architecture, not in colour. Only the data
  a variant actually shows is loaded.

  The dashboard is deliberately read-only. Marking attendance, recording money
  and cancelling classes all have exactly one home each, and duplicating a
  mutation here would mean two code paths guarding the same invariants.
  """
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Reporting, Roster, Studio}
  alias GaneshaWeb.Fmt

  @variants %{"a" => :day, "b" => :lanes, "c" => :ledger}
  @titles %{day: "今日", lanes: "四軌", ledger: "帳"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :month, Date.beginning_of_month(Clock.today()))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    variant = Map.get(@variants, params["variant"], :day)

    {:noreply,
     socket
     |> assign(:variant, variant)
     |> assign(:page_title, "總覽 · #{Map.fetch!(@titles, variant)}")
     |> load(variant)}
  end

  defp load(socket, :day) do
    session = Studio.next_session()
    owing = Reporting.outstanding_by_student()

    socket
    |> assign(:session, session)
    |> assign(:roster, if(session, do: Roster.list_for_session(session), else: []))
    |> assign(:revenue, Reporting.revenue_for_month(socket.assigns.month))
    |> assign(:owed, Enum.sum(Enum.map(owing, & &1.outstanding)))
    |> assign(:owing_count, length(owing))
  end

  defp load(socket, :lanes) do
    socket
    |> assign(:lanes, Reporting.month_lanes(socket.assigns.month))
    |> assign(:credits, Reporting.open_credits())
  end

  defp load(socket, :ledger) do
    assign(socket, :tax, Reporting.tax_threshold_status(socket.assigns.month))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:dashboard}>
      <.page_header title="總覽">
        <:subtitle>{Fmt.month_title(@month)}</:subtitle>
        <:actions>
          <.button navigate={~p"/publish"} variant="quiet">發布課表</.button>
        </:actions>
      </.page_header>

      <.variant_picker variant={@variant} />

      <.day :if={@variant == :day} {assigns} />
      <.lanes :if={@variant == :lanes} {assigns} />
      <.ledger :if={@variant == :ledger} {assigns} />
    </Layouts.app>
    """
  end

  # Three views of one studio, so the control that swaps them reads as one
  # object with three positions rather than three separate buttons.
  attr :variant, :atom, required: true

  defp variant_picker(assigns) do
    ~H"""
    <nav
      id="variant-picker"
      aria-label="總覽版面"
      class="mb-8 flex divide-x divide-rule border border-rule"
    >
      <.link
        :for={{key, variant, label, hint} <- variant_options()}
        id={"variant-#{key}"}
        patch={~p"/dashboard/#{key}"}
        aria-current={@variant == variant && "page"}
        class={[
          "flex min-h-11 flex-1 flex-col items-center justify-center px-2 py-2 leading-tight",
          @variant == variant && "bg-ink text-paper",
          @variant != variant && "text-ink-soft hover:bg-sunk"
        ]}
      >
        <span class="font-display text-base">{label}</span>
        <span class={["text-xs", @variant != variant && "text-ink-faint"]}>{hint}</span>
      </.link>
    </nav>
    """
  end

  defp variant_options do
    [
      {"a", :day, "今日", "下一堂"},
      {"b", :lanes, "四軌", "本月課表"},
      {"c", :ledger, "帳", "收款與稅"}
    ]
  end

  # ── a · 今日 ──────────────────────────────────────────────────────────────
  # Opens on the class itself, not on a number. For a studio, the next class
  # and the people in it are the most characteristic thing in the day.

  defp day(assigns) do
    ~H"""
    <div :if={@session} id="dash-next-session">
      <p class="font-display text-3xl leading-none text-ink">
        {Fmt.relative_day(@session.date, Clock.today())}
      </p>
      <p class="mt-2 text-sm text-ink-soft">{Fmt.date_with_weekday(@session.date)}</p>

      <div class={[
        "mt-5 flex items-start gap-4 border-l-[3px] pl-4",
        @session.state == "cancelled" && "border-sindoor",
        @session.state != "cancelled" && "border-ink"
      ]}>
        <.seal weekday={@session.date} size="lg" filled />
        <div class="min-w-0">
          <p class="font-display text-lg leading-snug text-ink">
            {Fmt.session_label(@session)}
          </p>
          <p class="font-display text-base text-ink-soft">
            {Fmt.session_time_range(@session)}
          </p>
          <p :if={@session.state == "cancelled"} class="mt-1 text-sm text-sindoor-ink">
            已取消 · {@session.cancel_reason}
          </p>
          <p :if={style_overridden?(@session)} class="mt-1">
            <.pill tone="turmeric">改上 {@session.style}</.pill>
          </p>
          <p :if={not style_overridden?(@session)} class="text-sm text-ink-soft">
            {@session.style}
          </p>
        </div>
      </div>

      <.section title="名單" count={length(@roster)}>
        <:actions>
          <.button navigate={~p"/sessions/#{@session.id}"} variant="quiet">開啟點名</.button>
        </:actions>

        <ul :if={@roster != []} class="space-y-px">
          <li
            :for={attendance <- @roster}
            id={"dash-attendance-#{attendance.id}"}
            class={["border-l-[3px] pl-4", roster_rule(attendance)]}
          >
            <.link
              navigate={~p"/sessions/#{@session.id}"}
              class="flex min-h-11 items-center justify-between gap-3 py-1"
            >
              <span class={[
                "font-display text-xl text-ink",
                attendance.state == "no_show" && "struck"
              ]}>
                {attendance.student.display_name}
              </span>
              <.pill tone={kind_tone(attendance.kind)}>{Fmt.kind(attendance.kind)}</.pill>
            </.link>
          </li>
        </ul>

        <.empty :if={@roster == []} id="dash-roster-empty">
          這堂還沒有人報名。
          <:action>
            <.button navigate={~p"/sessions/#{@session.id}"} variant="primary">加入學生</.button>
          </:action>
        </.empty>
      </.section>

      <.section title="這個月">
        <dl class="space-y-2">
          <div class="flex items-baseline justify-between gap-4">
            <dt class="text-sm text-ink-soft">已確認收入</dt>
            <dd><.money amount={@revenue} tone="turmeric" /></dd>
          </div>
          <div class="flex items-baseline justify-between gap-4">
            <dt class="text-sm text-ink-soft">
              {if @owing_count == 0, do: "款項都已收齊", else: "#{@owing_count} 人未收"}
            </dt>
            <dd>
              <.money amount={@owed} tone={if @owing_count == 0, do: "celadon", else: "sindoor"} />
            </dd>
          </div>
        </dl>
      </.section>
    </div>

    <.empty :if={is_nil(@session)} id="dash-no-session">
      接下來沒有排定的課。建立本月課程後，名單就會出現在這裡。
      <:action>
        <.button navigate={~p"/class"} variant="primary">建立本月課程</.button>
      </:action>
    </.empty>
    """
  end

  # ── b · 四軌 ──────────────────────────────────────────────────────────────
  # A studio's month is four recurring weekly classes with three or four dates
  # each. That is a timetable with four lanes, so this draws one.

  defp lanes(assigns) do
    ~H"""
    <div id="dash-lanes">
      <ul :if={@lanes != []} class="space-y-8">
        <li :for={lane <- @lanes} id={"lane-#{lane.slot.id}"}>
          <div class="flex items-start gap-3">
            <.seal weekday={lane.slot.weekday} />
            <div class="min-w-0">
              <p class="font-display text-lg leading-snug text-ink">
                {Fmt.slot_title(lane.slot.label)}
              </p>
              <p class="text-sm text-ink-soft">
                <span class="font-display">
                  {Fmt.time_range(lane.slot.start_time, lane.slot.end_time)}
                </span>
                · {lane.slot.default_style}
              </p>
            </div>
          </div>

          <div :if={lane.sessions != []} class="relative mt-4 pl-13">
            <span
              aria-hidden="true"
              class="absolute top-6 right-0 left-13 h-px bg-rule"
            />
            <ol class="relative flex gap-2">
              <li :for={entry <- lane.sessions}>
                <.link
                  navigate={~p"/sessions/#{entry.session.id}"}
                  id={"station-#{entry.session.id}"}
                  data-date={entry.session.date}
                  class="flex w-12 flex-col items-center gap-1"
                >
                  <span class={[
                    "flex size-12 items-center justify-center border bg-paper font-display text-base",
                    station_class(entry)
                  ]}>
                    {entry.session.date.day}
                  </span>
                  <span class={["text-xs", station_count_class(entry)]}>
                    {station_note(entry)}
                  </span>
                </.link>
              </li>
            </ol>
          </div>

          <.empty :if={lane.sessions == []} id={"lane-empty-#{lane.slot.id}"} class="mt-4 ml-13">
            本月尚未建立課程。
            <:action>
              <.button navigate={~p"/class/#{@month.year}/#{@month.month}"}>排這個月的課</.button>
            </:action>
          </.empty>
        </li>
      </ul>

      <.empty :if={@lanes == []} id="dash-no-slots">
        還沒有每週固定的課。在教室設定裡加入班次後，這裡會顯示每週的課表。
        <:action>
          <.button navigate={~p"/settings"} variant="primary">前往教室設定</.button>
        </:action>
      </.empty>

      <.section title="待處理" count={length(@credits) + length(unstaffed_dates(@lanes))}>
        <ul class="space-y-3">
          <li
            :for={credit <- @credits}
            id={"open-credit-#{credit.id}"}
            class="border-l-[3px] border-turmeric pl-4"
          >
            <p class="font-display text-base text-ink">
              {credit.student.display_name} · 補課未排
            </p>
            <p class="text-xs text-ink-faint">{credit_deadline(credit)}</p>
          </li>

          <li
            :for={entry <- unstaffed_dates(@lanes)}
            id={"empty-date-#{entry.session.id}"}
            class="border-l-[3px] border-rule pl-4"
          >
            <p class="font-display text-base text-ink">
              {Fmt.short_date(entry.session.date)} · 尚無名單
            </p>
            <p class="text-xs text-ink-faint">
              <.link navigate={~p"/sessions/#{entry.session.id}"} class="underline">加入學生</.link>
            </p>
          </li>

          <li :if={@credits == [] and unstaffed_dates(@lanes) == []}>
            <.empty id="nothing-pending">本月沒有待處理的補課或空名單。</.empty>
          </li>
        </ul>
      </.section>
    </div>
    """
  end

  # ── c · 帳 ────────────────────────────────────────────────────────────────
  # Money first, and the tax threshold as a real measure rather than a bar,
  # because crossing NT$50,000 in a month obliges 稅籍登記.

  defp ledger(assigns) do
    ~H"""
    <div id="dash-ledger">
      <div class="flex items-stretch justify-between gap-6">
        <div class="flex flex-col justify-end">
          <.money amount={@tax.revenue} size="xl" tone="turmeric" prefix="NT$" />
          <p class="mt-1 text-sm text-ink-soft">本月已確認收入</p>
          <p class="mt-4 text-sm text-ink-soft">
            距起徵點還有
            <span class="font-display text-base text-ink">
              NT${Fmt.amount(max(@tax.threshold - @tax.revenue, 0))}
            </span>
          </p>
        </div>

        <div class="flex shrink-0 items-end gap-2">
          <div class="text-right text-xs text-ink-faint">
            <p class="font-display">{Fmt.amount(@tax.threshold)}</p>
            <p>起徵點</p>
          </div>
          <div
            id="tax-measure"
            data-ratio={@tax.ratio}
            class="relative h-40 w-3 border-t border-rule-strong bg-sunk"
          >
            <div
              class={[
                "fills-up absolute inset-x-0 bottom-0",
                @tax.warn? && "bg-sindoor",
                !@tax.warn? && "bg-turmeric"
              ]}
              style={"height: #{measure_height(@tax.ratio)}%"}
            />
          </div>
        </div>
      </div>

      <p
        :if={@tax.warn?}
        id="dash-tax-warning"
        class="mt-5 border-l-[3px] border-sindoor bg-sindoor-lift px-4 py-3 text-sm"
      >
        本月收入已接近起徵點。單月超過就要辦理稅籍登記，逾期登記會從當月一日起補徵營業稅。
      </p>

      <.button navigate={~p"/money"} variant="quiet" class="mt-6">前往款項</.button>
    </div>
    """
  end

  # ── shared reading of state ───────────────────────────────────────────────

  # A session whose style differs from its slot's default is the studio's own
  # `*基礎8/26` convention, and the only style worth calling out.
  defp style_overridden?(%{slot: %{default_style: default}} = session),
    do: session.style != default

  defp style_overridden?(_session), do: false

  defp roster_rule(%{state: "no_show"}), do: "border-sindoor"
  defp roster_rule(%{kind: "makeup"}), do: "border-turmeric"
  defp roster_rule(_), do: "border-ink"

  defp kind_tone("makeup"), do: "turmeric"
  defp kind_tone("trial"), do: "celadon"
  defp kind_tone(_), do: "quiet"

  defp station_class(%{session: %{state: "cancelled"}}), do: "border-sindoor text-sindoor-ink"

  defp station_class(entry) do
    cond do
      style_overridden?(entry.session) -> "border-turmeric text-turmeric-ink"
      entry.total == 0 -> "border-rule text-ink-faint"
      true -> "border-ink text-ink"
    end
  end

  defp station_count_class(%{session: %{state: "cancelled"}}), do: "text-sindoor-ink"
  defp station_count_class(%{total: 0}), do: "text-ink-faint"
  defp station_count_class(_), do: "text-ink-soft"

  # One line under each date, carrying the single most important fact about it.
  defp station_note(%{session: %{state: "cancelled"}}), do: "取消"
  defp station_note(%{total: 0}), do: "—"
  defp station_note(%{total: total, no_show: 0}), do: "#{total} 人"
  defp station_note(%{total: total, no_show: absent}), do: "#{total - absent}/#{total}"

  defp unstaffed_dates(lanes) do
    for lane <- lanes,
        entry <- lane.sessions,
        entry.session.state == "scheduled",
        entry.total == 0,
        do: entry
  end

  defp credit_deadline(%{expires_on: nil}), do: "沒有使用期限"

  defp credit_deadline(%{expires_on: expires_on}) do
    case Date.diff(expires_on, Clock.today()) do
      0 -> "今天到期"
      days when days > 0 -> "#{Fmt.short_date(expires_on)} 到期 · 還有 #{days} 天"
      _ -> "#{Fmt.short_date(expires_on)} 已過期"
    end
  end

  # The measure is a level, so it keeps its scale past the threshold rather
  # than pretending the month stopped at 100%.
  defp measure_height(ratio), do: ratio |> min(1.0) |> max(0.0) |> Kernel.*(100) |> Float.round(1)
end
