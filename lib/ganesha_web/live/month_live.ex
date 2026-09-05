defmodule GaneshaWeb.MonthLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Repo, Roster, Studio}

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@month.year} 年 {@month.month} 月課表</h1>

        <section
          :for={%{slot: slot, sessions: sessions} <- @slots}
          id={"slot-#{slot.id}"}
          class="mt-4 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <header class="flex items-start justify-between gap-3">
            <h2 class="font-medium">{slot.label}</h2>
            <button
              :if={sessions == []}
              id={"generate-slot-#{slot.id}"}
              phx-click="generate"
              phx-value-slot-id={slot.id}
              class="min-h-[44px] rounded-lg bg-emerald-600 px-3 text-sm text-white"
            >
              建立本月
            </button>
            <.link
              :if={sessions != []}
              id={"enroll-slot-#{slot.id}"}
              navigate={~p"/enroll/#{slot.id}/#{@month.year}/#{@month.month}"}
              class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm leading-[44px] dark:border-zinc-700"
            >
              報名
            </.link>
          </header>

          <ul class="mt-3 space-y-3">
            <li
              :for={session <- sessions}
              data-date={session.date}
              class="rounded-xl border border-zinc-200 p-3 dark:border-zinc-800"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-mono text-sm">{session.date}</span>
                <span class={[
                  "rounded-full px-2 py-0.5 text-xs",
                  session.state == "cancelled" && "bg-red-100 text-red-700",
                  session.state == "scheduled" && "bg-zinc-100 text-zinc-600"
                ]}>
                  <%= if session.state == "cancelled" do %>
                    已停課 · {session.cancel_reason}
                  <% else %>
                    {session.style}
                  <% end %>
                </span>
              </div>

              <div :if={session.state == "scheduled"} class="mt-2 flex flex-wrap gap-2">
                <form id={"style-form-#{session.id}"} phx-submit="set_style" class="flex gap-2">
                  <input type="hidden" name="session-id" value={session.id} />
                  <input
                    type="text"
                    name="style"
                    value={session.style}
                    required
                    class="min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
                  />
                  <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
                    改課型
                  </button>
                </form>

                <form id={"cancel-form-#{session.id}"} phx-submit="cancel" class="flex gap-2">
                  <input type="hidden" name="session-id" value={session.id} />
                  <input
                    type="text"
                    name="reason"
                    placeholder="停課原因"
                    class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
                  />
                  <button class="min-h-[44px] rounded-lg border border-red-300 px-3 text-sm text-red-700">
                    停課
                  </button>
                </form>
              </div>
            </li>
          </ul>
        </section>
      </div>

      <Layouts.bottom_nav active={:month} />
    </Layouts.app>
    """
  end
end
