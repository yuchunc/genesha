defmodule GaneshaWeb.UserLive.Confirmation do
  use GaneshaWeb, :live_view

  alias Ganesha.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm py-8">
        <.page_header title="歡迎">
          <:subtitle>{@user.email}</:subtitle>
        </.page_header>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <div class="grid gap-2">
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="確認中…"
              variant="primary"
            >
              確認並保持登入
            </.button>
            <.button phx-disable-with="確認中…" variant="primary">
              確認並僅此次登入
            </.button>
          </div>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <div class="grid gap-2">
              <.button phx-disable-with="登入中…" variant="primary">
                登入
              </.button>
            </div>
          <% else %>
            <div class="grid gap-2">
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with="登入中…"
                variant="primary"
              >
                在此裝置保持登入
              </.button>
              <.button phx-disable-with="登入中…" variant="primary">
                僅此次登入
              </.button>
            </div>
          <% end %>
        </.form>

        <p
          :if={!@user.confirmed_at}
          class="mt-8 border-l-[3px] border-rule bg-sunk py-3 pl-4 text-sm text-ink-soft"
        >
          提示：若偏好使用密碼，可至帳戶設定啟用。
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "魔術連結無效或已過期。")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
