defmodule GaneshaWeb.SessionLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Enrolling, People, Roster, Studio}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, socket |> assign(:session, Studio.get_session!(id)) |> load()}
  end

  defp load(socket) do
    session = socket.assigns.session
    students = People.list_active_students()

    # Only offer credits usable on this session date; unusable credits would
    # surface errors the user cannot fix from this screen.
    eligible =
      Enum.filter(students, fn student ->
        Roster.available_credits(student.id, session.date) != []
      end)

    socket
    |> assign(:attendances, Roster.list_for_session(session))
    |> assign(:students, students)
    |> assign(:makeup_candidates, eligible)
    |> assign(
      :one_off_packages,
      Enum.reject(Catalog.list_active_packages(), &(&1.kind == "monthly"))
    )
  end

  @impl true
  def handle_event("add_one_off", params, socket) do
    if scheduled?(socket.assigns.session) do
      student = People.get_student!(params["student_id"])

      package =
        Enum.find(socket.assigns.one_off_packages, &(to_string(&1.id) == params["package_id"]))

      opts = [
        custom_amount: blank_to_nil(params["custom_amount"]),
        note: blank_to_nil(params["note"])
      ]

      case Enrolling.add_one_off(socket.assigns.session, student, package, opts) do
        {:ok, _result} ->
          {:noreply, socket |> put_flash(:info, "已加入 #{student.display_name}") |> load()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "無法加入，可能已在名單中")}
      end
    else
      {:noreply, put_flash(socket, :error, "已停課，不能加入單堂或體驗")}
    end
  end

  def handle_event("book_makeup", %{"student_id" => student_id}, socket) do
    if scheduled?(socket.assigns.session) do
      session = socket.assigns.session
      student = People.get_student!(student_id)

      case Roster.available_credits(student.id, session.date) do
        [credit | _] ->
          case Roster.book_makeup(session, student, credit) do
            {:ok, _attendance} ->
              {:noreply, socket |> put_flash(:info, "已安排補課") |> load()}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, makeup_error(reason))}
          end

        [] ->
          {:noreply, put_flash(socket, :error, "沒有可用的補課額度")}
      end
    else
      {:noreply, put_flash(socket, :error, "已停課，不能安排補課")}
    end
  end

  defp makeup_error(:credit_not_owned), do: "這張額度不屬於這位學生"
  defp makeup_error(:credit_already_consumed), do: "這張額度已使用"
  defp makeup_error(:credit_expired), do: "這張額度已過期"
  defp makeup_error(_other), do: "無法安排補課"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp scheduled?(session), do: session.state == "scheduled"

  defp attendee_label(attendance) do
    case attendance.kind do
      "makeup" -> "補課"
      "drop_in" -> "單堂"
      "trial" -> "體驗"
      _ -> "月課程"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@session.slot.label}</h1>
        <p class="text-sm text-zinc-500">{@session.date} · {@session.style}</p>

        <ul class="mt-4 space-y-2">
          <li
            :for={attendance <- @attendances}
            id={"attendance-#{attendance.id}"}
            class="flex items-center justify-between rounded-xl border border-zinc-200 p-3 dark:border-zinc-800"
          >
            <span>{attendance.student.display_name}</span>
            <span class="rounded-full bg-zinc-100 px-2 py-0.5 text-xs text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
              {attendee_label(attendance)}
            </span>
          </li>
          <li :if={@attendances == []} class="text-sm text-zinc-400">名單是空的</li>
        </ul>

        <h2 :if={scheduled?(@session)} class="mt-6 text-sm font-medium text-zinc-500">
          加入單堂／體驗
        </h2>
        <form
          :if={scheduled?(@session)}
          id="one-off-form"
          phx-submit="add_one_off"
          class="mt-2 space-y-2 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <select
            name="student_id"
            class="min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900"
          >
            <option :for={student <- @students} value={student.id}>{student.display_name}</option>
          </select>
          <select
            name="package_id"
            class="min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900"
          >
            <option :for={package <- @one_off_packages} value={package.id}>
              {package.name}（{package.price_per_class}）
            </option>
          </select>
          <div class="flex gap-2">
            <input
              type="number"
              name="custom_amount"
              placeholder="自訂金額"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="text"
              name="note"
              placeholder="備註"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
          </div>
          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">加入</button>
        </form>

        <div :if={scheduled?(@session) && @makeup_candidates != []}>
          <h2 class="mt-6 text-sm font-medium text-zinc-500">安排補課</h2>
          <form
            id="makeup-form"
            phx-submit="book_makeup"
            class="mt-2 flex gap-2 rounded-2xl border border-purple-200 p-4 dark:border-purple-900"
          >
            <select
              name="student_id"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 dark:bg-zinc-900"
            >
              <option :for={student <- @makeup_candidates} value={student.id}>
                {student.display_name}
              </option>
            </select>
            <button class="min-h-[44px] rounded-lg bg-purple-600 px-4 text-sm text-white">補課</button>
          </form>
        </div>
      </div>

      <Layouts.bottom_nav active={:month} />
    </Layouts.app>
    """
  end
end
