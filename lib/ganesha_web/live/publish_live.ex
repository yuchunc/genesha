defmodule GaneshaWeb.PublishLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Clock, Publishing}

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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <div class="flex items-center justify-between gap-2">
          <h1 class="text-lg font-semibold">{@month.month} 月公告</h1>
          <.link
            id="open-settings"
            navigate={~p"/settings"}
            class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm leading-[44px] dark:border-zinc-700"
          >
            設定
          </.link>
          <button
            id="copy-announcement"
            phx-hook=".CopyText"
            data-target="announcement-text"
            class="min-h-[44px] rounded-lg bg-emerald-600 px-4 text-sm text-white"
          >
            複製
          </button>
        </div>

        <pre
          id="announcement-text"
          phx-no-curly-interpolation
          class="mt-3 whitespace-pre-wrap rounded-2xl border border-zinc-200 p-4 text-sm leading-relaxed dark:border-zinc-800"
        ><%= @announcement %></pre>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">名單（自用）</h2>
        <pre
          id="roster-text"
          phx-no-curly-interpolation
          class="mt-2 whitespace-pre-wrap rounded-2xl border border-zinc-200 p-4 text-sm leading-relaxed dark:border-zinc-800"
        ><%= @roster %></pre>
      </div>

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

      <Layouts.bottom_nav active={:publish} />
    </Layouts.app>
    """
  end
end
