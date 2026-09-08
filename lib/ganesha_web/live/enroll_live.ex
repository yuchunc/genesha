defmodule GaneshaWeb.EnrollLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Clock, Enrolling, People, Reporting, Roster, Sales, Studio}
  alias GaneshaWeb.Fmt

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
    |> assign(:packages, Catalog.list_selectable_packages())
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

    student = Enum.find(socket.assigns.students, &(to_string(&1.id) == params["student_id"]))
    package = Enum.find(socket.assigns.packages, &(to_string(&1.id) == params["package_id"]))

    cond do
      chosen == [] ->
        {:noreply, put_flash(socket, :error, "請選擇上課日期")}

      student && package &&
          not Catalog.package_available?(
            package,
            Sales.purchased_package_ids_for_student(student.id)
          ) ->
        {:noreply, put_flash(socket, :error, "此方案已停用，僅開放曾購買過的學生續購")}

      true ->
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

  defp student_options(students), do: Enum.map(students, &{&1.display_name, &1.id})

  defp package_options(packages) do
    Enum.map(packages, &{"#{&1.name}（#{Fmt.amount(&1.price_per_class)}／堂）", &1.id})
  end

  defp payment_methods do
    Enum.map(~w(line_pay line_bank cash other), &{Fmt.method(&1), &1})
  end

  # The left rule carries how much of this month is still owed.
  defp purchase_rule(%{payable: payable, paid: paid}) when payable > 0 and paid >= payable,
    do: "border-celadon"

  defp purchase_rule(%{payable: payable, paid: paid}) when payable - paid > 0,
    do: "border-turmeric"

  defp purchase_rule(_row), do: "border-ink"

  # `Reporting.purchase_period/1` aggregates the date column, so the value
  # arrives as a Date or as its ISO string depending on the adapter.
  defp period_text(%{first: first, last: last}), do: "#{period_date(first)}–#{period_date(last)}"

  defp period_date(%Date{} = date), do: Fmt.short_date(date)

  defp period_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> Fmt.short_date(date)
      _ -> iso
    end
  end

  defp summary_class do
    "flex min-h-11 w-fit cursor-pointer list-none items-center text-sm text-ink-faint transition-colors hover:text-ink [&::-webkit-details-marker]:hidden"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav={:class}
      back={~p"/class/#{@month.year}/#{@month.month}"}
    >
      <div class="flex items-start gap-3" aria-label={@slot.label}>
        <.seal weekday={@slot.weekday} size="lg" class="mt-1" />
        <div class="min-w-0 flex-1">
          <.page_header title={Fmt.slot_title(@slot.label)}>
            <:subtitle>{Fmt.month_title(@month)}</:subtitle>
          </.page_header>
        </div>
      </div>

      <.section title="新增名單">
        <form id="enroll-form" phx-submit="enroll" class="space-y-4">
          <.input
            type="select"
            name="student_id"
            value={nil}
            label="學生"
            options={student_options(@students)}
          />

          <.input
            type="select"
            name="package_id"
            value={nil}
            label="方案"
            options={package_options(@packages)}
          />

          <fieldset>
            <legend class="mb-1.5 text-xs text-ink-soft">上課日期</legend>

            <div :if={@scheduled != []} class="flex flex-wrap gap-2">
              <label :for={session <- @scheduled} class="cursor-pointer">
                <input
                  type="checkbox"
                  id={"session-check-#{session.id}"}
                  name="session_ids[]"
                  value={session.id}
                  checked
                  class="peer sr-only"
                />
                <span class="flex min-h-11 items-center gap-1 border border-rule-strong px-3 text-ink transition-colors peer-checked:border-turmeric peer-checked:bg-turmeric-lift peer-checked:text-turmeric-ink peer-focus-visible:border-turmeric peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-turmeric">
                  <span class="font-display tabular-nums">{Fmt.short_date(session.date)}</span>
                  <span :if={session.style != @slot.default_style} class="text-xs">
                    *{session.style}
                  </span>
                </span>
              </label>
            </div>

            <p :if={@scheduled == []} class="text-sm text-ink-soft">
              本月尚未建立課程，請先回到課表建立。
            </p>
          </fieldset>

          <div>
            <.input
              type="number"
              name="custom_amount"
              value=""
              label="整月金額（留空則依方案計算）"
              inputmode="numeric"
            />
            <p class="mt-1 text-xs text-ink-faint">常用金額 400、450、800、900、1,200、1,600</p>
          </div>

          <.input type="text" name="note" value="" label="備註" placeholder="例如：友情價" />

          <.button variant="primary">加入名單</.button>
        </form>

        <div :if={@scheduled != []} class="mt-6 border-t border-rule pt-2">
          <p class="text-xs text-ink-soft">開啟單日名單</p>
          <div class="flex flex-wrap">
            <.button
              :for={session <- @scheduled}
              variant="quiet"
              id={"open-session-#{session.id}"}
              navigate={~p"/sessions/#{session.id}"}
            >
              <span class="font-display tabular-nums">{Fmt.short_date(session.date)}</span>
            </.button>
          </div>
        </div>
      </.section>

      <.section title="本月名單" count={length(@enrollments)}>
        <.empty :if={@enrollments == []} id="no-enrollments">
          本月還沒有人報名。在上面選好學生與日期，加入第一位。
        </.empty>

        <div
          :for={row <- @enrollments}
          id={"purchase-#{row.purchase.id}"}
          class={["mt-5 border-l-[3px] pl-4", purchase_rule(row)]}
        >
          <div class="flex items-baseline justify-between gap-3">
            <.link
              navigate={~p"/students/#{row.student.id}"}
              class="font-display text-lg text-ink transition-colors hover:text-turmeric-ink"
            >
              {row.student.display_name}
            </.link>

            <.money
              :if={row.payable - row.paid > 0}
              amount={row.payable - row.paid}
              label="待收"
              tone="turmeric"
            />
            <.pill :if={row.paid >= row.payable} tone="celadon">已收齊</.pill>
          </div>

          <div
            class="mt-1 flex flex-wrap items-baseline gap-x-4"
            aria-label={"NT$ #{row.paid} / #{row.payable}"}
          >
            <span :if={row.period} class="font-display text-xs tabular-nums text-ink-faint">
              {period_text(row.period)}
            </span>
            <.money amount={row.paid} label="已收" size="sm" tone="soft" />
            <.money amount={row.payable} label="應收" size="sm" tone="soft" />
          </div>

          <details class="mt-1">
            <summary class={summary_class()}>記錄收款</summary>

            <form
              id={"payment-form-#{row.purchase.id}"}
              phx-submit="record_payment"
              class="mt-1 space-y-3 pb-3"
            >
              <input type="hidden" name="purchase-id" value={row.purchase.id} />

              <.input
                type="number"
                name="amount"
                value={row.payable - row.paid}
                label="金額"
                inputmode="numeric"
              />

              <.input
                type="select"
                name="method"
                value="line_pay"
                label="收款方式"
                options={payment_methods()}
              />

              <.input
                type="text"
                name="reported_last5"
                value=""
                label="帳號末五碼（選填）"
                inputmode="numeric"
              />

              <.button variant="accent">記錄收款</.button>
            </form>
          </details>
        </div>
      </.section>
    </Layouts.app>
    """
  end
end
