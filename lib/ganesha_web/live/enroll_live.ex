defmodule GaneshaWeb.EnrollLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Clock, Enrolling, People, Reporting, Roster, Sales, Studio}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"slot_id" => slot_id} = params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:slot, Studio.get_slot!(slot_id))
     |> assign_month(params)
     |> load()}
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
    sessions = Studio.sessions_for_slot_in_month(socket.assigns.slot, socket.assigns.month)
    scheduled = Enum.filter(sessions, &(&1.state == "scheduled"))

    socket
    |> assign(:sessions, sessions)
    |> assign(:scheduled, scheduled)
    |> assign(:students, People.list_active_students())
    |> assign(:packages, Catalog.list_active_packages())
    |> assign(:enrollments, enrollments_for(scheduled))
  end

  # Purchases reachable from this slot-month, derived through the attendance
  # rows on its sessions. There is no month column to query directly.
  defp enrollments_for(sessions) do
    sessions
    |> Enum.flat_map(&Roster.list_for_session/1)
    |> Enum.filter(&(&1.kind == "enrolled" and &1.purchase_id))
    |> Enum.uniq_by(& &1.purchase_id)
    |> Enum.map(fn attendance ->
      purchase = Sales.get_purchase!(attendance.purchase_id)

      %{
        purchase: purchase,
        student: purchase.student,
        payable: Sales.payable(purchase),
        paid: confirmed_paid(purchase.id),
        period: Reporting.purchase_period(purchase.id)
      }
    end)
    |> Enum.sort_by(& &1.student.display_name)
  end

  defp confirmed_paid(purchase_id) do
    purchase_id
    |> Sales.list_payments_for_purchase()
    |> Enum.filter(&(&1.state == "confirmed"))
    |> Enum.map(& &1.amount)
    |> Enum.sum()
  end

  @impl true
  def handle_event("enroll", params, socket) do
    session_ids = Map.get(params, "session_ids", [])

    chosen =
      Enum.filter(socket.assigns.scheduled, &(to_string(&1.id) in session_ids))

    cond do
      chosen == [] ->
        {:noreply, put_flash(socket, :error, "請選擇上課日期")}

      true ->
        student = Enum.find(socket.assigns.students, &(to_string(&1.id) == params["student_id"]))
        package = Enum.find(socket.assigns.packages, &(to_string(&1.id) == params["package_id"]))

        case Enrolling.enroll_month(%{
               student: student,
               slot: socket.assigns.slot,
               package: package,
               sessions: chosen,
               custom_amount: blank_to_nil(params["custom_amount"]),
               note: blank_to_nil(params["note"])
             }) do
          {:ok, _result} ->
            {:noreply, socket |> put_flash(:info, "已加入 #{student.display_name}") |> load()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "無法加入，可能已在名單中")}
        end
    end
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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">{@slot.label}</h1>
        <p class="text-sm text-zinc-500">{@month.year} 年 {@month.month} 月報名</p>

        <form
          id="enroll-form"
          phx-submit="enroll"
          class="mt-4 space-y-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <label class="block text-sm">
            學生
            <select
              name="student_id"
              class="mt-1 min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900"
            >
              <option :for={student <- @students} value={student.id}>{student.display_name}</option>
            </select>
          </label>

          <label class="block text-sm">
            方案
            <select
              name="package_id"
              class="mt-1 min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900"
            >
              <option :for={package <- @packages} value={package.id}>
                {package.name}（{package.price_per_class}／堂）
              </option>
            </select>
          </label>

          <fieldset>
            <legend class="text-sm">上課日期</legend>
            <div class="mt-1 flex flex-wrap gap-2">
              <label
                :for={session <- @scheduled}
                class="flex min-h-[44px] items-center gap-2 rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700"
              >
                <input
                  type="checkbox"
                  id={"session-check-#{session.id}"}
                  name="session_ids[]"
                  value={session.id}
                  checked
                  class="size-5"
                />
                {session.date.month}/{session.date.day}
              </label>
            </div>
          </fieldset>

          <div class="flex flex-wrap gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
            <.link
              :for={session <- @scheduled}
              id={"open-session-#{session.id}"}
              navigate={~p"/sessions/#{session.id}"}
              class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm leading-[44px] dark:border-zinc-700"
            >
              {session.date.month}/{session.date.day} 名單
            </.link>
          </div>

          <div class="flex flex-wrap gap-2">
            <input
              type="number"
              name="custom_amount"
              placeholder="自訂金額（可留空）"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="text"
              name="note"
              placeholder="備註"
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
          </div>

          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">
            加入名單
          </button>
        </form>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">本月名單</h2>
        <section
          :for={row <- @enrollments}
          id={"purchase-#{row.purchase.id}"}
          class="mt-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <header class="flex items-baseline justify-between gap-2">
            <.link navigate={~p"/students/#{row.student.id}"} class="font-medium">
              {row.student.display_name}
            </.link>
            <span class="font-mono text-sm">
              NT$ {row.paid} / {row.payable}
            </span>
          </header>

          <p :if={row.period} class="mt-1 text-xs text-zinc-500">
            {row.period.first} – {row.period.last}
          </p>

          <form
            id={"payment-form-#{row.purchase.id}"}
            phx-submit="record_payment"
            class="mt-3 flex flex-wrap gap-2"
          >
            <input type="hidden" name="purchase-id" value={row.purchase.id} />
            <input
              type="number"
              name="amount"
              placeholder="金額"
              value={row.payable - row.paid}
              class="min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <select
              name="method"
              class="min-h-[44px] rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            >
              <option value="line_pay">Line Pay</option>
              <option value="line_bank">LINE Bank</option>
              <option value="cash">現金</option>
              <option value="other">其他</option>
            </select>
            <input
              type="text"
              name="reported_last5"
              placeholder="帳後五碼"
              inputmode="numeric"
              class="min-h-[44px] w-28 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              記錄
            </button>
          </form>
        </section>

        <p :if={@enrollments == []} id="no-enrollments" class="mt-3 text-sm text-zinc-400">
          還沒有人報名
        </p>
      </div>

      <Layouts.bottom_nav active={:month} />
    </Layouts.app>
    """
  end
end
