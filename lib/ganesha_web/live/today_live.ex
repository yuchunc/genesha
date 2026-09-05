defmodule GaneshaWeb.TodayLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Roster, Studio}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket)}
  end

  defp load(socket) do
    case Studio.next_session() do
      nil ->
        socket
        |> assign(:session, nil)
        |> stream(:attendances, [], reset: true, dom_id: &"attendance-#{&1.id}")

      session ->
        socket
        |> assign(:session, session)
        |> stream(:attendances, Roster.list_for_session(session),
          reset: true,
          dom_id: &"attendance-#{&1.id}"
        )
    end
  end

  @impl true
  def handle_event("toggle_no_show", %{"id" => id}, socket) do
    attendance = Roster.get_attendance!(id)

    {:ok, _updated} =
      case attendance.state do
        "expected" -> Roster.mark_no_show(attendance)
        "no_show" -> Roster.mark_expected(attendance)
      end

    # get_attendance!/1 preloads [:student, session: :slot], which does not
    # match the [:student, purchase: :package] shape every other row in this
    # stream has (from list_for_session/1). Re-derive the row through that
    # same accessor so the stream never mixes preload shapes across rows.
    refreshed =
      socket.assigns.session
      |> Roster.list_for_session()
      |> Enum.find(&(&1.id == attendance.id))

    {:noreply, stream_insert(socket, :attendances, refreshed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <%= if @session do %>
          <section
            id="today-session"
            class="rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
          >
            <h1 class="text-lg font-semibold">{@session.slot.label}</h1>
            <p class="mt-1 text-sm text-zinc-500">{@session.date} · {@session.style}</p>
          </section>

          <ul id="attendances" phx-update="stream" class="mt-4 space-y-2">
            <li
              :for={{dom_id, attendance} <- @streams.attendances}
              id={dom_id}
              data-state={attendance.state}
              class="flex items-center justify-between rounded-xl border border-zinc-200 p-3 dark:border-zinc-800"
            >
              <span class={[
                "text-base",
                attendance.state == "no_show" && "line-through text-zinc-400"
              ]}>
                {attendance.student.display_name}
              </span>
              <button
                id={"no-show-#{attendance.id}"}
                phx-click="toggle_no_show"
                phx-value-id={attendance.id}
                class="min-h-[44px] min-w-[44px] rounded-lg px-3 text-sm text-zinc-600 hover:bg-zinc-100
                       dark:text-zinc-300 dark:hover:bg-zinc-800"
              >
                {if attendance.state == "no_show", do: "已到", else: "未到"}
              </button>
            </li>
          </ul>
        <% else %>
          <p
            id="no-upcoming-session"
            class="rounded-2xl border border-dashed border-zinc-300 p-8 text-center text-zinc-500 dark:border-zinc-700"
          >
            目前沒有排定的課程
          </p>
        <% end %>
      </div>

      <Layouts.bottom_nav active={:today} />
    </Layouts.app>
    """
  end
end
