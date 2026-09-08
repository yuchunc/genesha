defmodule GaneshaWeb.MonthLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Repo, Roster, Studio}
  alias GaneshaWeb.Fmt

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_month(params) |> load_month()}
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

  defp load_month(socket) do
    month = socket.assigns.month
    sessions = Studio.sessions_in_month(month)
    counts = Roster.count_by_session(Enum.map(sessions, & &1.id))
    active_slots = Studio.list_active_slots()
    recurring_this_month? = Enum.any?(sessions, & &1.slot_id)

    previous_had_recurring? =
      month |> prev_month() |> Studio.sessions_in_month() |> Enum.any?(& &1.slot_id)

    socket
    |> assign(:calendar_cells, calendar_cells(month, sessions, counts))
    |> assign(:agenda_dates, agenda_dates(sessions, counts))
    |> assign(:roster_slots, roster_slots(active_slots, sessions))
    |> assign(
      :show_copy_prompt,
      active_slots != [] and not recurring_this_month? and previous_had_recurring?
    )
  end

  # One entry per day of the month, `nil` for the blank cells before the 1st
  # so the grid's columns line up with the weekday header.
  defp calendar_cells(%Date{} = month, sessions, counts) do
    by_date = Enum.group_by(sessions, & &1.date)
    first = Date.beginning_of_month(month)
    leading = Date.day_of_week(first) - 1

    days =
      Enum.map(Date.range(first, Clock.end_of_month(month)), fn date ->
        %{
          date: date,
          marks:
            by_date
            |> Map.get(date, [])
            |> Enum.map(fn session ->
              %{cancelled?: session.state == "cancelled", count: Map.get(counts, session.id, 0)}
            end)
        }
      end)

    List.duplicate(nil, leading) ++ days
  end

  # One entry per date that has a session, chronological, each carrying
  # every session on that date in time order — a date with two overlapping
  # classes renders two rows under one heading.
  defp agenda_dates(sessions, counts) do
    sessions
    |> Enum.group_by(& &1.date)
    |> Enum.sort_by(fn {date, _sessions} -> date end, Date)
    |> Enum.map(fn {date, day_sessions} ->
      %{
        date: date,
        entries:
          day_sessions
          |> Enum.sort_by(&session_start_time/1, Time)
          |> Enum.map(&%{session: &1, count: Map.get(counts, &1.id, 0)})
      }
    end)
  end

  defp session_start_time(%{slot: %{start_time: time}}), do: time
  defp session_start_time(session), do: session.start_time

  # Active slots with at least one session this month — the "本月名單" strip
  # links to the slot+month enrollment flow, which only makes sense once
  # there is something to enroll into.
  defp roster_slots(active_slots, sessions) do
    slot_ids_with_sessions = sessions |> Enum.filter(& &1.slot_id) |> MapSet.new(& &1.slot_id)
    Enum.filter(active_slots, &MapSet.member?(slot_ids_with_sessions, &1.id))
  end

  defp style_override?(%{slot: %{default_style: default}} = session), do: session.style != default
  defp style_override?(_session), do: false

  @impl true
  def handle_event("copy_previous_month", _params, socket) do
    {:ok, created} = Studio.copy_month(socket.assigns.month)

    {:noreply,
     socket
     |> put_flash(:info, "已複製 #{created} 堂課")
     |> load_month()}
  end

  def handle_event("dismiss_copy_prompt", _params, socket) do
    {:noreply, assign(socket, :show_copy_prompt, false)}
  end

  def handle_event("set_style", %{"session-id" => id, "style" => style}, socket) do
    {:ok, _session} = id |> Studio.get_session!() |> Studio.set_style(style)

    {:noreply, socket |> put_flash(:info, "已更新課型") |> load_month()}
  end

  def handle_event("cancel", %{"session-id" => id, "reason" => reason}, socket) do
    session = Studio.get_session!(id)

    # Credits are issued here rather than inside Studio so both steps are
    # visible at the call site; wrapped in one transaction so a session is
    # never left cancelled without its students' makeup credits, or the
    # reverse — the render guard hides the cancel form once state flips, so
    # there is no UI path to retry a partial failure.
    result =
      Repo.transaction(fn ->
        case Studio.cancel_session(session, reason) do
          {:ok, cancelled} ->
            {:ok, credits} = Roster.issue_cancellation_credits(cancelled)
            credits

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, credits} ->
        {:noreply,
         socket
         |> put_flash(:info, "已停課，發出 #{length(credits)} 張補課額度")
         |> load_month()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請填寫停課原因")}
    end
  end

  # The month either side of the one on screen, for the header's navigation
  # and the copy-prompt check.
  defp prev_month(%Date{} = month), do: month |> Date.beginning_of_month() |> Date.add(-1)
  defp next_month(%Date{} = month), do: month |> Date.end_of_month() |> Date.add(1)

  defp month_path(%Date{} = month), do: ~p"/class/#{month.year}/#{month.month}"

  # The left rule carries the date's state.
  defp session_rule(%{state: "cancelled"}), do: "border-sindoor"
  defp session_rule(_session), do: "border-rule"

  # A disclosure control that reads as quiet text, with the native marker gone
  # and a 44px tap target kept.
  defp summary_class do
    "flex min-h-11 w-fit cursor-pointer list-none items-center text-sm text-ink-faint transition-colors hover:text-ink [&::-webkit-details-marker]:hidden"
  end

  attr :cell, :any, required: true

  defp calendar_cell(%{cell: nil} = assigns) do
    ~H"""
    <span></span>
    """
  end

  defp calendar_cell(assigns) do
    ~H"""
    <a
      href={"#date-#{@cell.date}"}
      id={"cal-#{@cell.date}"}
      class="flex aspect-square flex-col items-center justify-center gap-0.5 bg-paper-raised text-sm"
    >
      <span class="font-display tabular-nums">{@cell.date.day}</span>
      <span :if={@cell.marks != []} class="flex gap-0.5">
        <span
          :for={mark <- @cell.marks}
          class={[
            "flex h-3.5 min-w-3.5 items-center justify-center border px-0.5 text-[9px] tabular-nums",
            mark.cancelled? && "border-sindoor text-sindoor-ink",
            !mark.cancelled? && "border-turmeric-ink text-turmeric-ink"
          ]}
        >
          {mark.count}
        </span>
      </span>
    </a>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:class}>
      <.page_header title={Fmt.month_title(@month)}>
        <:actions>
          <.button variant="quiet" navigate={month_path(prev_month(@month))} aria-label="上個月">
            <.icon name="hero-chevron-left" class="size-5" />
          </.button>
          <.button variant="quiet" navigate={month_path(next_month(@month))} aria-label="下個月">
            <.icon name="hero-chevron-right" class="size-5" />
          </.button>
          <.button variant="quiet" navigate={~p"/publish"}>發布課表</.button>
        </:actions>
      </.page_header>

      <div class="mt-2">
        <.button variant="primary" navigate={~p"/class/new?year=#{@month.year}&month=#{@month.month}"}>
          排課
        </.button>
      </div>

      <div
        :if={@show_copy_prompt}
        id="copy-prompt"
        class="mt-6 flex items-center justify-between gap-3 border-l-[3px] border-rule py-3 pl-4"
      >
        <p class="text-sm text-ink-soft">
          要複製 {Fmt.month_title(prev_month(@month))} 的課表嗎？
        </p>
        <div class="flex shrink-0 items-center gap-2">
          <.button id="copy-previous-month" variant="primary" phx-click="copy_previous_month">
            複製
          </.button>
          <.button
            id="dismiss-copy-prompt"
            variant="quiet"
            phx-click="dismiss_copy_prompt"
            aria-label="不用了"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </.button>
        </div>
      </div>

      <div class="mt-6 border border-rule p-3">
        <div class="grid grid-cols-7 gap-px pb-2 text-center text-xs text-ink-faint">
          <span :for={weekday <- 1..7}>{Fmt.weekday_glyph(weekday)}</span>
        </div>
        <div class="grid grid-cols-7 gap-px">
          <.calendar_cell :for={cell <- @calendar_cells} cell={cell} />
        </div>
      </div>

      <div :if={@roster_slots != []} class="mt-6 space-y-1">
        <.link
          :for={slot <- @roster_slots}
          id={"enroll-slot-#{slot.id}"}
          navigate={~p"/enroll/#{slot.id}/#{@month.year}/#{@month.month}"}
          class="flex min-h-11 items-center gap-2 text-ink transition-colors hover:text-turmeric-ink"
        >
          <.seal weekday={slot.weekday} size="sm" />
          <span class="font-display">{Fmt.slot_title(slot.label)}</span>
          <span class="ml-auto text-sm text-ink-soft">本月名單</span>
        </.link>
      </div>

      <.empty :if={@agenda_dates == []} id="no-sessions" class="mt-8">
        本月還沒有課程。用上面的「排課」建立第一堂課。
      </.empty>

      <div :if={@agenda_dates != []} id="agenda" class="slides-in mt-8 space-y-6">
        <div :for={day <- @agenda_dates} id={"date-#{day.date}"} data-date={day.date}>
          <h2 class="font-display text-lg text-ink">{Fmt.date_with_weekday(day.date)}</h2>

          <ul class="mt-2 space-y-2">
            <li
              :for={entry <- day.entries}
              id={"session-#{entry.session.id}"}
              class={["border-l-[3px] pl-4", session_rule(entry.session)]}
            >
              <.link
                navigate={~p"/sessions/#{entry.session.id}"}
                class="flex min-h-11 items-center gap-2 text-ink transition-colors hover:text-turmeric-ink"
              >
                <span class="font-display tabular-nums">{Fmt.session_time_range(entry.session)}</span>
                <span class="text-ink-soft">{Fmt.session_label(entry.session)}</span>
                <.pill :if={style_override?(entry.session)} tone="turmeric">
                  {entry.session.style}
                </.pill>
                <.pill :if={entry.session.state == "cancelled"} tone="sindoor">已取消</.pill>
                <span class="ml-auto shrink-0 text-sm text-ink-soft">{entry.count} 人</span>
              </.link>

              <p
                :if={entry.session.state == "cancelled" and entry.session.cancel_reason}
                class="pb-2 text-xs text-sindoor-ink"
              >
                {entry.session.cancel_reason}
              </p>

              <details :if={entry.session.state == "scheduled"} class="pb-1">
                <summary class={summary_class()}>調整</summary>

                <div class="mt-1 space-y-4 pb-3">
                  <form
                    id={"style-form-#{entry.session.id}"}
                    phx-submit="set_style"
                    class="flex items-end gap-2"
                  >
                    <input type="hidden" name="session-id" value={entry.session.id} />
                    <div class="flex-1">
                      <.input
                        type="text"
                        name="style"
                        value={entry.session.style}
                        label="課型"
                        required
                      />
                    </div>
                    <.button variant="primary">更新課型</.button>
                  </form>

                  <form
                    id={"cancel-form-#{entry.session.id}"}
                    phx-submit="cancel"
                    class="flex items-end gap-2"
                  >
                    <input type="hidden" name="session-id" value={entry.session.id} />
                    <div class="flex-1">
                      <.input
                        type="text"
                        name="reason"
                        value=""
                        label="停課原因"
                        placeholder="例如：颱風假"
                      />
                    </div>
                    <.button variant="danger">停課</.button>
                  </form>
                </div>
              </details>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
