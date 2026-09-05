defmodule GaneshaWeb.SettingsLive do
  use GaneshaWeb, :live_view

  alias Ganesha.{Catalog, Publishing}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  defp load(socket) do
    settings = Publishing.get_settings()

    socket
    |> assign(:packages, Catalog.list_packages())
    |> assign(:settings_form, to_form(Publishing.change_settings(settings), as: :settings))
  end

  @impl true
  def handle_event("create_package", %{"package" => params}, socket) do
    case Catalog.create_package(params) do
      {:ok, _package} -> {:noreply, socket |> put_flash(:info, "已新增方案") |> load()}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "方案資料不正確")}
    end
  end

  def handle_event("save_package", %{"package-id" => id} = params, socket) do
    package = Catalog.get_package!(id)

    attrs = %{
      price_per_class: params["price_per_class"],
      included_makeups: params["included_makeups"]
    }

    case Catalog.update_package(package, attrs) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "已更新方案") |> load()}
      {:error, _} -> {:noreply, put_flash(socket, :error, "金額不正確")}
    end
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    case Publishing.update_settings(params) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "已儲存") |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset, as: :settings))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">方案與設定</h1>

        <form
          id="new-package-form"
          phx-submit="create_package"
          class="mt-3 space-y-2 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <h2 class="font-medium">新增方案</h2>
          <input
            type="text"
            name="package[name]"
            placeholder="方案名稱"
            required
            class="min-h-[44px] w-full rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
          />
          <select
            name="package[kind]"
            class="min-h-[44px] w-full rounded-lg border-zinc-300 dark:bg-zinc-900"
          >
            <option value="monthly">月課程</option>
            <option value="drop_in">單堂</option>
            <option value="trial">體驗</option>
          </select>
          <div class="flex gap-2">
            <input
              type="number"
              name="package[price_per_class]"
              placeholder="每堂"
              required
              class="min-h-[44px] flex-1 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
            <input
              type="number"
              name="package[included_makeups]"
              value="0"
              class="min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
            />
          </div>
          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">新增</button>
        </form>

        <section
          :for={package <- @packages}
          id={"package-#{package.id}"}
          class="mt-3 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <h2 class="font-medium">
            {package.name}<span class="ml-2 text-xs text-zinc-500">{package.kind}</span>
          </h2>

          <form
            id={"package-form-#{package.id}"}
            phx-submit="save_package"
            class="mt-2 flex flex-wrap items-center gap-2"
          >
            <input type="hidden" name="package-id" value={package.id} />
            <label class="text-xs text-zinc-500">
              每堂
              <input
                type="number"
                name="price_per_class"
                value={package.price_per_class}
                class="ml-1 min-h-[44px] w-24 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
              />
            </label>
            <label class="text-xs text-zinc-500">
              補課數
              <input
                type="number"
                name="included_makeups"
                value={package.included_makeups}
                class="ml-1 min-h-[44px] w-20 rounded-lg border-zinc-300 text-sm dark:bg-zinc-900"
              />
            </label>
            <button class="min-h-[44px] rounded-lg border border-zinc-300 px-3 text-sm dark:border-zinc-700">
              儲存
            </button>
          </form>
        </section>

        <h2 class="mt-6 text-sm font-medium text-zinc-500">匯款資訊（公告用）</h2>
        <.form
          for={@settings_form}
          id="studio-settings-form"
          phx-submit="save_settings"
          class="mt-2 space-y-2 rounded-2xl border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <.input field={@settings_form[:bank_name]} type="text" label="銀行名稱" />
          <.input field={@settings_form[:bank_code]} type="text" label="銀行代號" />
          <.input field={@settings_form[:account_number]} type="text" label="帳號" />
          <.input field={@settings_form[:transfer_deadline]} type="text" label="轉帳期限" />
          <.input field={@settings_form[:closing_note]} type="text" label="結尾備註" />
          <button class="min-h-[44px] w-full rounded-lg bg-emerald-600 text-sm text-white">儲存</button>
        </.form>
      </div>

      <Layouts.bottom_nav active={:publish} />
    </Layouts.app>
    """
  end
end
