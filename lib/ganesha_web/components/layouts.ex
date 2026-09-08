defmodule GaneshaWeb.Layouts do
  @moduledoc """
  App chrome: the top bar, the thumb-reachable bottom navigation, and flashes.

  Design system: `docs/superpowers/specs/2026-09-06-ui-design-system.md`.
  """
  use GaneshaWeb, :html

  alias Ganesha.Clock
  alias GaneshaWeb.Fmt

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app shell.

  The top bar carries today's Taipei date, which is useful on every screen, and
  the two controls that are not navigation. The bottom bar carries navigation,
  within thumb reach.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:dashboard}>
        <h1>Content</h1>
      </Layouts.app>

      <Layouts.app flash={@flash} current_scope={@current_scope} nav={:none} back={~p"/class"}>
        <h1>A screen with no tab of its own</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :nav, :any,
    default: nil,
    doc: "active nav key, `:none` for a screen with no tab, `nil` for no nav at all"

  attr :back, :string, default: nil, doc: "path for the back affordance"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh bg-paper">
      <header class="border-b border-rule">
        <div class="mx-auto flex max-w-measure items-center gap-3 px-5 py-3">
          <.link
            :if={@back}
            navigate={@back}
            aria-label="返回"
            class="-ml-2 inline-flex size-11 items-center justify-center text-ink-soft hover:text-ink"
          >
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>

          <p class="font-display text-base text-ink-soft">
            {Fmt.date_with_weekday(Clock.today())}
          </p>

          <div class="ml-auto flex items-center gap-1">
            <.theme_toggle />
            <.link
              :if={@current_scope}
              navigate={~p"/settings"}
              aria-label="設定"
              class="inline-flex size-11 items-center justify-center text-ink-soft hover:text-ink"
            >
              <.icon name="hero-cog-6-tooth" class="size-5" />
            </.link>
          </div>
        </div>
      </header>

      <main class={["mx-auto max-w-measure px-5 pt-6", @nav && "pb-32", !@nav && "pb-12"]}>
        {render_slot(@inner_block)}
      </main>

      <.bottom_nav :if={@nav} active={@nav} />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("連線中斷")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("正在重新連線，你的操作會在連上後送出。")}
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("伺服器沒有回應")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("正在重新連線。重新整理頁面可以更快恢復。")}
      </.flash>
    </div>
    """
  end

  @doc """
  Light, dark, or follow the device.

  Three square glyphs divided by hairlines. The `data-phx-theme` attribute and
  the `phx:set-theme` event are the contract with the inline script in
  `root.html.heex`, which applies the theme before first paint.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="flex items-center divide-x divide-rule border border-rule">
      <button
        class="flex size-9 cursor-pointer items-center justify-center text-ink-faint hover:text-ink [[data-theme-source=system]_&]:bg-ink [[data-theme-source=system]_&]:text-paper"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="跟隨系統"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="flex size-9 cursor-pointer items-center justify-center text-ink-faint hover:text-ink [[data-theme-source=user][data-theme=light]_&]:bg-ink [[data-theme-source=user][data-theme=light]_&]:text-paper"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="淺色"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="flex size-9 cursor-pointer items-center justify-center text-ink-faint hover:text-ink [[data-theme-source=user][data-theme=dark]_&]:bg-ink [[data-theme-source=user][data-theme=dark]_&]:text-paper"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="深色"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end

  @doc """
  Thumb-reachable bottom navigation.

  She works on a phone, switching between LINE and this app, so navigation sits
  at the bottom within thumb reach and every target is at least 44px tall. The
  active tab is marked by a turmeric rule along its top edge — the horizontal
  answer to the left state rules used throughout the content.

  `active` may be `:none` for screens that have no tab of their own; the bar
  still renders so she can leave.
  """
  attr :active, :atom, required: true

  def bottom_nav(assigns) do
    ~H"""
    <nav
      id="bottom-nav"
      aria-label="主要導覽"
      class="fixed inset-x-0 bottom-0 z-40 flex border-t border-rule bg-raised pb-[env(safe-area-inset-bottom)] shadow-[0_-1px_12px_rgba(22,35,63,0.06)]"
    >
      <.nav_item
        active={@active}
        key={:dashboard}
        path={~p"/dashboard"}
        icon="hero-book-open"
        label="總覽"
      />
      <.nav_item
        active={@active}
        key={:class}
        path={~p"/class"}
        icon="hero-calendar-days"
        label="課表"
      />
      <.nav_item active={@active} key={:money} path={~p"/money"} icon="hero-banknotes" label="款項" />
      <.nav_item
        active={@active}
        key={:students}
        path={~p"/students"}
        icon="hero-user-group"
        label="學生"
      />
    </nav>
    """
  end

  attr :active, :atom, required: true
  attr :key, :atom, required: true
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_item(assigns) do
    ~H"""
    <.link
      id={"nav-#{@key}"}
      navigate={@path}
      aria-current={@active == @key && "page"}
      class={[
        "relative flex min-h-[60px] flex-1 flex-col items-center justify-center gap-1 py-2.5 text-xs",
        @active == @key && "text-turmeric-ink",
        @active != @key && "text-ink-faint"
      ]}
    >
      <span
        :if={@active == @key}
        aria-hidden="true"
        class="absolute inset-x-0 top-0 h-[2px] bg-turmeric"
      />
      <.icon name={@icon} class="size-5" />
      {@label}
    </.link>
    """
  end
end
