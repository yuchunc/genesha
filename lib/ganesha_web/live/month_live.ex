defmodule GaneshaWeb.MonthLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Repo, Roster, Studio}
  alias GaneshaWeb.Fmt

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign_month(params) |> load_slots()}
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

  defp load_slots(socket) do
    month = socket.assigns.month

    slots =
      Enum.map(Studio.list_active_slots(), fn slot ->
        %{slot: slot, sessions: Studio.sessions_for_slot_in_month(slot, month)}
      end)

    assign(socket, :slots, slots)
  end

  @impl true
  def handle_event("generate", %{"slot-id" => slot_id}, socket) do
    {:ok, _sessions} =
      slot_id |> Studio.get_slot!() |> Studio.generate_month(socket.assigns.month)

    {:noreply, socket |> put_flash(:info, "已建立本月課程") |> load_slots()}
  end

  def handle_event("set_style", %{"session-id" => id, "style" => style}, socket) do
    {:ok, _session} = id |> Studio.get_session!() |> Studio.set_style(style)

    {:noreply, socket |> put_flash(:info, "已更新課型") |> load_slots()}
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
         |> load_slots()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請填寫停課原因")}
    end
  end

  # The month either side of the one on screen, for the header's navigation.
  defp prev_month(%Date{} = month), do: month |> Date.beginning_of_month() |> Date.add(-1)
  defp next_month(%Date{} = month), do: month |> Date.end_of_month() |> Date.add(1)

  defp month_path(%Date{} = month), do: ~p"/month/#{month.year}/#{month.month}"

  # The left rule carries the date's state.
  defp session_rule(%{state: "cancelled"}), do: "border-sindoor"
  defp session_rule(_session), do: "border-rule"

  # A disclosure control that reads as quiet text, with the native marker gone
  # and a 44px tap target kept.
  defp summary_class do
    "flex min-h-11 w-fit cursor-pointer list-none items-center text-sm text-ink-faint transition-colors hover:text-ink [&::-webkit-details-marker]:hidden"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:month}>
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
      <section
        :for={%{slot: slot, sessions: sessions} <- @slots}
        id={"slot-#{slot.id}"}
        class="mt-8"
      >
        <div class="flex items-center gap-3 border-b border-rule pb-2">
          <.seal weekday={slot.weekday} />
          <div class="min-w-0 flex-1">
            <h2 class="font-display text-lg leading-tight text-ink">{Fmt.slot_title(slot.label)}</h2>
            <p class="mt-0.5 text-sm text-ink-soft">
              {Fmt.time_range(slot.start_time, slot.end_time)} · {slot.default_style}
            </p>
          </div>
          <.button
            :if={sessions != []}
            variant="quiet"
            id={"enroll-slot-#{slot.id}"}
            navigate={~p"/enroll/#{slot.id}/#{@month.year}/#{@month.month}"}
          >
            本月名單
          </.button>
        </div>

        <.empty :if={sessions == []} class="mt-3">
          本月尚未建立課程。
          <:action>
            <.button
              variant="primary"
              id={"generate-slot-#{slot.id}"}
              phx-click="generate"
              phx-value-slot-id={slot.id}
            >
              建立本月課程
            </.button>
          </:action>
        </.empty>

        <ul :if={sessions != []} class="mt-3 space-y-2">
          <li
            :for={session <- sessions}
            data-date={session.date}
            class={["border-l-[3px] pl-4", session_rule(session)]}
          >
            <.link
              navigate={~p"/sessions/#{session.id}"}
              class="flex min-h-11 items-center gap-2 text-ink transition-colors hover:text-turmeric-ink"
            >
              <span class="font-display text-lg tabular-nums">{Fmt.short_date(session.date)}</span>
              <.pill :if={session.style != slot.default_style} tone="turmeric">
                {session.style}
              </.pill>
              <.pill :if={session.state == "cancelled"} tone="sindoor">已取消</.pill>
            </.link>

            <p
              :if={session.state == "cancelled" and session.cancel_reason}
              class="pb-2 text-xs text-sindoor-ink"
            >
              {session.cancel_reason}
            </p>

            <details :if={session.state == "scheduled"} class="pb-1">
              <summary class={summary_class()}>調整</summary>

              <div class="mt-1 space-y-4 pb-3">
                <form
                  id={"style-form-#{session.id}"}
                  phx-submit="set_style"
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="session-id" value={session.id} />
                  <div class="flex-1">
                    <.input type="text" name="style" value={session.style} label="課型" required />
                  </div>
                  <.button variant="primary">更新課型</.button>
                </form>

                <form
                  id={"cancel-form-#{session.id}"}
                  phx-submit="cancel"
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="session-id" value={session.id} />
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
      </section>
    </Layouts.app>
    """
  end
end
