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
      included_makeups: params["included_makeups"],
      active: params["active"],
      grandfather_strategy: params["grandfather_strategy"]
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
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:none} back={~p"/dashboard"}>
      <.page_header title="教室設定">
        <:subtitle>價目表與匯款資訊</:subtitle>
      </.page_header>

      <.section title="價目表" count={length(@packages)}>
        <div class="space-y-6">
          <div
            :for={package <- @packages}
            id={"package-#{package.id}"}
            class={[
              "border-l-[3px] pl-4",
              if(package.active, do: "border-ink", else: "border-rule")
            ]}
          >
            <div class="flex items-baseline justify-between gap-3">
              <p class="font-display text-lg text-ink">{package.name}</p>
              <div class="flex items-center gap-2">
                <.pill :if={!package.active} tone={availability_tone(package)}>
                  {availability_label(package)}
                </.pill>
                <.pill tone={package_tone(package.kind)}>{package_kind(package.kind)}</.pill>
              </div>
            </div>

            <div class="mt-1 flex items-baseline justify-between gap-3">
              <.money amount={package.price_per_class} label="每堂" />
              <p class="text-xs text-ink-faint">{makeup_note(package.included_makeups)}</p>
            </div>

            <details class="mt-1">
              <summary class="flex min-h-11 list-none items-center text-sm text-ink-soft transition-colors hover:text-ink">
                編輯
              </summary>

              <form id={"package-form-#{package.id}"} phx-submit="save_package" class="space-y-3">
                <input type="hidden" name="package-id" value={package.id} />
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    type="number"
                    name="price_per_class"
                    value={package.price_per_class}
                    label="每堂金額"
                  />
                  <.input
                    type="number"
                    name="included_makeups"
                    value={package.included_makeups}
                    label="補課次數"
                  />
                </div>
                <.input
                  type="checkbox"
                  name="active"
                  value={package.active}
                  label="開放新學生購買"
                />
                <.input
                  type="select"
                  name="grandfather_strategy"
                  value={package.grandfather_strategy}
                  label="停用後，曾購買過的學生"
                  options={[{"不可續購", "none"}, {"仍可續購", "past_purchasers"}]}
                />
                <.button variant="primary">儲存方案</.button>
              </form>
            </details>
          </div>
        </div>
      </.section>

      <.section title="新增方案">
        <form id="new-package-form" phx-submit="create_package" class="space-y-3">
          <.input
            type="text"
            name="package[name]"
            value=""
            label="方案名稱"
            placeholder="例：月課程"
            required
          />
          <.input
            type="select"
            name="package[kind]"
            value="monthly"
            label="類型"
            options={[{"月課程", "monthly"}, {"單堂", "drop_in"}, {"體驗", "trial"}]}
          />
          <div class="grid grid-cols-2 gap-3">
            <.input
              type="number"
              name="package[price_per_class]"
              value=""
              label="每堂金額"
              required
            />
            <.input type="number" name="package[included_makeups]" value="0" label="補課次數" />
          </div>
          <.button variant="primary">新增方案</.button>
        </form>
      </.section>

      <.section title="匯款資訊">
        <p class="mb-4 text-sm text-ink-soft">
          這裡填的內容會出現在每月發布給學生的課表公告裡。
        </p>

        <.form
          for={@settings_form}
          id="studio-settings-form"
          phx-submit="save_settings"
          class="space-y-3"
        >
          <.input field={@settings_form[:bank_name]} type="text" label="銀行名稱" />
          <.input field={@settings_form[:bank_code]} type="text" label="銀行代號" />
          <.input field={@settings_form[:account_number]} type="text" label="帳號" />
          <.input field={@settings_form[:transfer_deadline]} type="text" label="轉帳期限" />
          <.input field={@settings_form[:closing_note]} type="text" label="結尾備註" />
          <.button variant="primary">儲存匯款資訊</.button>
        </.form>
      </.section>

      <.section title="帳戶">
        <div class="border-l-[3px] border-rule pl-4">
          <p class="font-display text-base text-ink">{@current_scope.user.email}</p>

          <div class="mt-3 flex flex-wrap items-center gap-2">
            <.button navigate={~p"/users/settings"}>變更 Email 或密碼</.button>
            <.button variant="quiet" href={~p"/users/log-out"} method="delete">登出</.button>
          </div>
        </div>
      </.section>
    </Layouts.app>
    """
  end

  # Package kinds are the studio's own words, not the database's. `Fmt.kind/1`
  # names attendance kinds, which are a different set.
  defp package_kind("monthly"), do: "月課程"
  defp package_kind("drop_in"), do: "單堂"
  defp package_kind("trial"), do: "體驗"
  defp package_kind(other), do: other

  defp package_tone("monthly"), do: "ink"
  defp package_tone(_other), do: "quiet"

  # The entitlement is a promise to the student, so it reads as one.
  defp makeup_note(n) when is_integer(n) and n > 0, do: "含 #{n} 次補課"
  defp makeup_note(_none), do: "不含補課"

  # An inactive package with grandfather rights is a live promise to whoever
  # already holds it, not a dead entry — the pill carries that distinction.
  defp availability_tone(%{grandfather_strategy: "past_purchasers"}), do: "turmeric"
  defp availability_tone(_package), do: "quiet"

  defp availability_label(%{grandfather_strategy: "past_purchasers"}), do: "已停用．舊生可續購"
  defp availability_label(_package), do: "已停用"
end
