defmodule GaneshaWeb.UserLive.Login do
  use GaneshaWeb, :live_view

  alias Ganesha.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>登入</p>
            <:subtitle :if={@current_scope}>
              進行敏感操作前請重新驗證身分
            </:subtitle>
          </.header>
        </div>

        <div
          :if={local_mail_adapter?()}
          class="flex gap-3 rounded-lg border border-sky-200 bg-sky-50 p-4 text-sm text-sky-900 dark:border-sky-800 dark:bg-sky-950 dark:text-sky-100"
        >
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>目前使用本機郵件轉接器。</p>
            <p>
              若要查看已寄出的郵件，請前往 <.link href="/dev/mailbox" class="underline">信箱頁面</.link>。
            </p>
          </div>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_magic"
          action={~p"/users/log-in"}
          phx-submit="submit_magic"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="電子郵件"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button variant="primary">
            以電子郵件登入 <span aria-hidden="true">→</span>
          </.button>
        </.form>

        <div class="flex items-center gap-3 text-sm text-stone-500">
          <span class="h-px flex-1 bg-stone-200 dark:bg-stone-700"></span>
          或 <span class="h-px flex-1 bg-stone-200 dark:bg-stone-700"></span>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label="電子郵件"
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label="密碼"
            autocomplete="current-password"
            spellcheck="false"
          />
          <div class="space-y-2">
            <.button variant="primary" name={@form[:remember_me].name} value="true">
              登入並保持登入 <span aria-hidden="true">→</span>
            </.button>
            <.button variant="primary">
              僅此次登入
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info = "若系統中有此電子郵件，您將很快收到登入說明。"

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:ganesha, Ganesha.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
