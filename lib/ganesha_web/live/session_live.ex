defmodule GaneshaWeb.SessionLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Enrolling, People, Roster, Sales, Studio}
  alias GaneshaWeb.Fmt

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
      Enum.reject(Catalog.list_selectable_packages(), &(&1.kind == "monthly"))
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

      cond do
        not Catalog.package_available?(
          package,
          Sales.purchased_package_ids_for_student(student.id)
        ) ->
          {:noreply, put_flash(socket, :error, "此方案已停用，僅開放曾購買過的學生續購")}

        true ->
          case Enrolling.add_one_off(socket.assigns.session, student, package, opts) do
            {:ok, _result} ->
              {:noreply, socket |> put_flash(:info, "已加入 #{student.display_name}") |> load()}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "無法加入，可能已在名單中")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "已停課，不能加入單堂或體驗")}
    end
  end

  def handle_event("toggle_no_show", %{"id" => id}, socket) do
    attendance = Roster.get_attendance!(id)

    {:ok, _updated} =
      case attendance.state do
        "expected" -> Roster.mark_no_show(attendance)
        "no_show" -> Roster.mark_expected(attendance)
      end

    {:noreply, load(socket)}
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

  defp student_options(students), do: Enum.map(students, &{&1.display_name, &1.id})

  defp package_options(packages) do
    Enum.map(packages, fn package ->
      {"#{package.name}（NT$#{Fmt.amount(package.price_per_class)}）", package.id}
    end)
  end

  # An expiring credit is the reason she is on this screen, so the option says
  # which credit will be spent. `book_makeup` takes the first available credit
  # and `available_credits/2` orders soonest-expiry first, so this is the one.
  defp makeup_options(candidates, %Date{} = date) do
    Enum.map(candidates, fn student ->
      {"#{student.display_name} · #{credit_expiry(student, date)}", student.id}
    end)
  end

  defp credit_expiry(student, date) do
    case Roster.available_credits(student.id, date) do
      [%{expires_on: nil} | _] -> "無期限"
      [%{expires_on: expires_on} | _] -> "#{Fmt.short_date(expires_on)} 到期"
      [] -> "無可用額度"
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, cancelled: assigns.session.state == "cancelled", style_override: style_override?(assigns.session))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:month} back={~p"/month"}>
      <.page_header title={Fmt.date_with_weekday(@session.date)}>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.seal
              weekday={@session.date}
              size="sm"
              tone={if @cancelled, do: "sindoor", else: "ink"}
            />
            <span class="font-display text-ink">{Fmt.session_label(@session)}</span>
            <span class="font-display">{Fmt.session_time_range(@session)}</span>
            <.pill :if={@style_override} tone="turmeric">{@session.style}</.pill>
            <span :if={@session.style && !@style_override}>{@session.style}</span>
          </span>
        </:subtitle>
        <:actions>
          <.pill :if={@cancelled} tone="sindoor">已取消</.pill>
        </:actions>
      </.page_header>

      <p
        :if={@cancelled && @session.cancel_reason}
        class="border-l-[3px] border-sindoor py-2 pl-4 text-sm text-sindoor-ink"
      >
        {@session.cancel_reason}
      </p>

      <.section title="名單" count={length(@attendances)}>
        <ul :if={@attendances != []} class="space-y-2">
          <li
            :for={attendance <- @attendances}
            id={"attendance-#{attendance.id}"}
            data-state={attendance.state}
            class={[
              "flex min-h-11 items-center gap-3 border-l-[3px] py-1.5 pl-4",
              row_rule(attendance)
            ]}
          >
            <div class="min-w-0 flex-1">
              <p class="font-display text-lg leading-snug text-ink">
                <span :if={attendance.state == "no_show"} class="struck">
                  {attendance.student.display_name}
                </span>
                <span :if={attendance.state != "no_show"}>
                  {attendance.student.display_name}
                </span>
              </p>
              <p :if={attendance.note} class="text-xs text-ink-faint">{attendance.note}</p>
            </div>
            <.pill tone={if attendance.kind == "makeup", do: "turmeric", else: "quiet"}>
              {Fmt.kind(attendance.kind)}
            </.pill>

            <.button
              id={"no-show-#{attendance.id}"}
              variant="quiet"
              phx-click="toggle_no_show"
              phx-value-id={attendance.id}
            >
              {if attendance.state == "no_show", do: "取消未到", else: "標記未到"}
            </.button>
          </li>
        </ul>
        <.empty :if={@attendances == []}>這堂還沒有人。用下面的表單加入。</.empty>
      </.section>

      <.section :if={scheduled?(@session)} title="加入單堂或體驗">
        <form id="one-off-form" phx-submit="add_one_off" class="space-y-3">
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
            options={package_options(@one_off_packages)}
          />
          <div class="flex gap-3">
            <div class="flex-1">
              <.input type="number" name="custom_amount" value={nil} label="自訂金額" />
            </div>
            <div class="flex-1">
              <.input type="text" name="note" value={nil} label="備註" />
            </div>
          </div>
          <.button variant="primary">加入名單</.button>
        </form>
      </.section>

      <.section :if={scheduled?(@session) && @makeup_candidates != []} title="安排補課">
        <form id="makeup-form" phx-submit="book_makeup" class="space-y-3">
          <.input
            type="select"
            name="student_id"
            value={nil}
            label="學生與即將到期的額度"
            options={makeup_options(@makeup_candidates, @session.date)}
          />
          <.button variant="accent">安排補課</.button>
        </form>
      </.section>
    </Layouts.app>
    """
  end

  defp style_override?(%{slot: %{default_style: default}} = session), do: session.style != default
  defp style_override?(_session), do: false

  # The same left rule the Dashboard uses for a roster row, so every screen
  # reads as one ledger.
  defp row_rule(%{state: "no_show"}), do: "border-sindoor"
  defp row_rule(%{kind: "makeup"}), do: "border-turmeric"
  defp row_rule(_attendance), do: "border-ink"
end
