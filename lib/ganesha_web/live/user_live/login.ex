defmodule GaneshaWeb.UserLive.Login do
  use GaneshaWeb, :live_view

  alias Ganesha.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm py-8">
        <.page_header title="登入">
          <:subtitle :if={@current_scope}>進行敏感操作前請重新驗證身分</:subtitle>
          <:subtitle :if={!@current_scope}>教室的課表與帳簿</:subtitle>
        </.page_header>

        <div
          :if={local_mail_adapter?()}
          class="mb-8 border-l-[3px] border-turmeric bg-turmeric-lift py-3 pl-4 text-sm text-ink-soft"
        >
          <p>目前使用本機郵件轉接器。</p>
          <p>
            若要查看已寄出的郵件，請前往 <.link href="/dev/mailbox" class="text-turmeric-ink underline">信箱頁面</.link>。
          </p>
        </div>

        <.section title="用電子郵件連結登入">
          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
            class="grid gap-4"
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
            <.button variant="primary">以電子郵件登入</.button>
          </.form>
        </.section>

        <.section title="用密碼登入">
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="grid gap-4"
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
              field={f[:password]}
              type="password"
              label="密碼"
              autocomplete="current-password"
              spellcheck="false"
            />
            <div class="grid gap-2">
              <.button variant="primary" name={f[:remember_me].name} value="true">
                登入並保持登入
              </.button>
              <.button>僅此次登入</.button>
            </div>
          </.form>
        </.section>
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
