defmodule GaneshaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use GaneshaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex items-center justify-end px-4 py-2 sm:px-6">
      <.theme_toggle />
    </header>

    <main class="mx-auto max-w-2xl px-4 pb-4 sm:px-6">
      {render_slot(@inner_block)}
    </main>

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
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex items-center rounded-full border border-zinc-300 bg-zinc-100 dark:border-zinc-600 dark:bg-zinc-800">
      <div class="absolute left-0 h-full w-1/3 rounded-full border border-zinc-300 bg-white shadow-sm transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 dark:border-zinc-500 dark:bg-zinc-600" />

      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  Thumb-reachable bottom navigation.

  She works on a phone, switching between LINE and this app, so navigation sits
  at the bottom within thumb reach and every target is at least 44px tall.

  Only `/` exists when this task lands, so it is the only entry using `~p`.
  The other four are plain string literals matching their eventual route paths
  exactly, because `~p` is a compile-time-verified route and `mix precommit`
  runs `compile --warnings-as-errors` — a `~p` sigil for a route that doesn't
  exist yet is a warning that becomes a hard failure. Tasks 13 (`/month`),
  14 (`/students`), 15 (`/money`, `/publish`) each convert their own line from
  a string back to `~p` in the same commit that adds the matching route.
  """
  attr :active, :atom, required: true

  def bottom_nav(assigns) do
    ~H"""
    <nav
      id="bottom-nav"
      aria-label="主要導覽"
      class="fixed bottom-0 inset-x-0 z-40 flex border-t border-zinc-200 bg-white/95 backdrop-blur
             pb-[env(safe-area-inset-bottom)] dark:border-zinc-800 dark:bg-zinc-900/95"
    >
      <.nav_item active={@active} key={:today} path={~p"/"} icon="hero-sun" label="今天" />
      <.nav_item
        active={@active}
        key={:month}
        path={~p"/month"}
        icon="hero-calendar-days"
        label="月課表"
      />
      <.nav_item active={@active} key={:money} path="/money" icon="hero-banknotes" label="收款" />
      <.nav_item
        active={@active}
        key={:students}
        path={~p"/students"}
        icon="hero-users"
        label="學生"
      />
      <.nav_item active={@active} key={:publish} path="/publish" icon="hero-share" label="發布" />
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
        "flex flex-1 flex-col items-center justify-center gap-1 py-3 min-h-[56px] text-xs",
        @active == @key && "text-emerald-600 dark:text-emerald-400",
        @active != @key && "text-zinc-500 dark:text-zinc-400"
      ]}
    >
      <.icon name={@icon} class="w-6 h-6" />
      {@label}
    </.link>
    """
  end
end
