defmodule GaneshaWeb.PublishLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Publishing}
  alias GaneshaWeb.Fmt

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign_month(socket, params)}
  end

  defp assign_month(socket, %{"year" => year, "month" => month}) do
    with {y, ""} <- Integer.parse(year),
         {m, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(y, m, 1) do
      put_month(socket, date)
    else
      _ -> assign_month(socket, %{})
    end
  end

  defp assign_month(socket, _params) do
    put_month(socket, Date.beginning_of_month(Clock.today()))
  end

  defp put_month(socket, %Date{} = month) do
    socket
    |> assign(:month, month)
    |> assign(:announcement, Publishing.announcement(month))
    |> assign(:roster, Publishing.roster_block(month))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:none} back={~p"/class"}>
      <.page_header title="發布課表">
        <:subtitle>{Fmt.month_title(@month)}</:subtitle>
        <:actions>
          <.button
            variant="quiet"
            navigate={month_path(@month, -1)}
            aria-label={"上一個月 " <> Fmt.month_title(sibling_month(@month, -1))}
          >
            {month_label(@month, -1)}
          </.button>
          <.button
            variant="quiet"
            navigate={month_path(@month, 1)}
            aria-label={"下一個月 " <> Fmt.month_title(sibling_month(@month, 1))}
          >
            {month_label(@month, 1)}
          </.button>
        </:actions>
      </.page_header>

      <p class="text-sm text-ink-soft">
        以下是學生在 LINE 群組裡會看到的訊息，複製後直接貼上就可以發布。
      </p>

      <%!-- grid stretches its only child, so the copy control fills the phone's width --%>
      <div class="mt-4 grid">
        <.button
          id="copy-announcement"
          variant="accent"
          phx-hook=".CopyText"
          data-target="announcement-text"
        >
          複製到 LINE
        </.button>
      </div>

      <pre
        id="announcement-text"
        class="mt-4 max-w-[28rem] border-l-[3px] border-turmeric bg-raised px-5 py-4 font-ui text-base leading-relaxed break-words whitespace-pre-wrap text-ink"
      >{@announcement}</pre>

      <div class="mt-4 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 border-t border-rule pt-3">
        <p class="text-sm text-ink-soft">訊息結尾的轉帳資訊來自設定。</p>
        <.button id="open-settings" variant="quiet" navigate={~p"/settings"}>
          修改轉帳資訊
        </.button>
      </div>

      <.section title="教室自用名單">
        <p class="text-sm text-ink-soft">
          這份名單只給教室自己核對出席，補課與單堂都標在名字旁邊。學生收到的訊息不會有這一段。
        </p>
        <pre
          id="roster-text"
          class="mt-3 border-l-[3px] border-rule bg-sunk px-5 py-4 font-ui text-sm leading-relaxed break-words whitespace-pre-wrap text-ink-soft"
        >{@roster}</pre>
      </.section>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyText">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const source = document.getElementById(this.el.dataset.target)
              if (!source) return
              const original = this.el.textContent
              try {
                await navigator.clipboard.writeText(source.innerText)
                this.el.textContent = "已複製"
                setTimeout(() => { this.el.textContent = original }, 1500)
              } catch (_error) {
                // Clipboard permission can be denied; select the text instead so
                // she can still copy it with a long press.
                const range = document.createRange()
                range.selectNodeContents(source)
                const selection = window.getSelection()
                selection.removeAllRanges()
                selection.addRange(range)
              }
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp month_path(%Date{} = month, delta) do
    target = sibling_month(month, delta)
    ~p"/publish/#{target.year}/#{target.month}"
  end

  defp month_label(%Date{} = month, delta), do: "#{sibling_month(month, delta).month}月"

  defp sibling_month(%Date{} = month, delta), do: Date.shift(month, month: delta)
end
