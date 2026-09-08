defmodule GaneshaWeb.ScheduleLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Studio}
  alias GaneshaWeb.Fmt

  @modes ~w(standalone recurring)

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    mode = if params["mode"] in @modes, do: params["mode"], else: "standalone"

    {:noreply, socket |> assign_month(params) |> assign(:mode, mode)}
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

  @impl true
  def handle_event("create_standalone", %{"session" => params}, socket) do
    attrs =
      params
      |> Map.put("state", "scheduled")
      |> normalize_times(["start_time", "end_time"])

    case Studio.create_session(attrs) do
      {:ok, session} ->
        {:noreply,
         push_navigate(socket, to: ~p"/class/#{session.date.year}/#{session.date.month}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "請確認日期、時間與名稱都已填寫")}
    end
  end

  def handle_event("create_recurring", %{"slot" => params}, socket) do
    attrs = normalize_times(params, ["start_time", "end_time"])

    case Studio.create_slot(attrs) do
      {:ok, slot} ->
        {:ok, _sessions} = Studio.generate_month(slot, socket.assigns.month)
        month = socket.assigns.month
        {:noreply, push_navigate(socket, to: ~p"/class/#{month.year}/#{month.month}")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, recurring_error(changeset))}
    end
  end

  # A native <input type="time"> submits "HH:MM" without seconds; Ecto's
  # :time cast wants "HH:MM:SS".
  defp normalize_times(params, keys) do
    Enum.reduce(keys, params, fn key, acc -> Map.update(acc, key, nil, &normalize_time/1) end)
  end

  defp normalize_time(hm) when is_binary(hm) and byte_size(hm) == 5, do: hm <> ":00"
  defp normalize_time(other), do: other

  defp weekday_options, do: Enum.map(1..7, &{Fmt.weekday(&1), &1})

  defp recurring_error(changeset) do
    if Enum.any?(changeset.errors, fn {_field, {msg, _opts}} ->
         msg == "has already been taken"
       end) do
      "已經有相同星期與時間的固定班次了"
    else
      "請確認星期、時間與名稱都已填寫"
    end
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
      <.page_header title="排課">
        <:subtitle>{Fmt.month_title(@month)}</:subtitle>
      </.page_header>

      <nav
        id="schedule-mode"
        aria-label="排課方式"
        class="mb-8 flex divide-x divide-rule border border-rule"
      >
        <.link
          :for={{key, label} <- [{"standalone", "單次"}, {"recurring", "固定班次"}]}
          id={"mode-#{key}"}
          patch={~p"/class/new?year=#{@month.year}&month=#{@month.month}&mode=#{key}"}
          aria-current={@mode == key && "page"}
          class={[
            "flex min-h-11 flex-1 items-center justify-center px-2 py-2 font-display text-base",
            @mode == key && "bg-ink text-paper",
            @mode != key && "text-ink-soft hover:bg-sunk"
          ]}
        >
          {label}
        </.link>
      </nav>

      <form
        :if={@mode == "standalone"}
        id="standalone-form"
        phx-submit="create_standalone"
        class="space-y-3"
      >
        <.input type="date" name="session[date]" value="" label="日期" required />
        <.input type="time" name="session[start_time]" value="" label="開始時間" required />
        <.input type="time" name="session[end_time]" value="" label="結束時間" required />
        <.input type="text" name="session[label]" value="" label="課程名稱" required />
        <.input type="text" name="session[style]" value="" label="課型" required />
        <.button variant="primary">排這堂課</.button>
      </form>

      <form
        :if={@mode == "recurring"}
        id="recurring-form"
        phx-submit="create_recurring"
        class="space-y-3"
      >
        <.input
          type="select"
          name="slot[weekday]"
          options={weekday_options()}
          value=""
          prompt="請選擇星期"
          label="星期"
          required
        />
        <.input type="time" name="slot[start_time]" value="" label="開始時間" required />
        <.input type="time" name="slot[end_time]" value="" label="結束時間" required />
        <.input type="text" name="slot[label]" value="" label="課程名稱" required />
        <.input type="text" name="slot[default_style]" value="" label="課型" required />
        <input type="hidden" name="slot[active]" value="true" />
        <.button variant="primary">建立固定班次</.button>
      </form>
    </Layouts.app>
    """
  end
end
