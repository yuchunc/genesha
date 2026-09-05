defmodule GaneshaWeb.StudentLive.Index do
  use GaneshaWeb, :live_view

  alias Ganesha.People
  alias Ganesha.People.Student

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(People.change_student(%Student{})))
     |> stream(:students, People.list_students())}
  end

  @impl true
  def handle_event("save", %{"student" => params}, socket) do
    case People.create_student(params) do
      {:ok, student} ->
        {:noreply,
         socket
         |> stream_insert(:students, student, at: 0)
         |> assign(:form, to_form(People.change_student(%Student{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="pb-24">
        <h1 class="text-lg font-semibold">學生</h1>

        <.form for={@form} id="student-form" phx-submit="save" class="mt-3 flex items-end gap-2">
          <.input field={@form[:display_name]} type="text" placeholder="姓名" />
          <button class="min-h-[44px] rounded-lg bg-emerald-600 px-4 text-sm text-white">新增</button>
        </.form>

        <ul id="students" phx-update="stream" class="mt-4 space-y-2">
          <li :for={{_dom_id, student} <- @streams.students} id={"student-#{student.id}"}>
            <.link
              navigate={~p"/students/#{student.id}"}
              class="flex min-h-[56px] items-center justify-between rounded-xl border border-zinc-200 px-4 dark:border-zinc-800"
            >
              <span>{student.display_name}</span>
              <.icon name="hero-chevron-right" class="w-5 h-5 text-zinc-400" />
            </.link>
          </li>
        </ul>
      </div>

      <Layouts.bottom_nav active={:students} />
    </Layouts.app>
    """
  end
end
