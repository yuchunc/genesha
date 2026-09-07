defmodule GaneshaWeb.StudentLive.Index do
  use GaneshaWeb, :live_view

  alias Ganesha.People
  alias Ganesha.People.Student

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(People.change_student(%Student{})))
     |> stream(:students, People.list_students(), dom_id: &"student-#{&1.id}")}
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
    <Layouts.app flash={@flash} current_scope={@current_scope} nav={:students}>
      <.page_header title="學生" />

      <.section title="新增學生">
        <.form for={@form} id="student-form" phx-submit="save" class="flex items-start gap-2">
          <div class="flex-1">
            <.input field={@form[:display_name]} type="text" placeholder="姓名" />
          </div>
          <.button variant="primary">加入學生</.button>
        </.form>
      </.section>

      <.section title="全部學生">
        <ul id="students" phx-update="stream" class="space-y-1">
          <li
            :for={{dom_id, student} <- @streams.students}
            id={dom_id}
            class="border-l-[3px] border-rule"
          >
            <.link
              navigate={~p"/students/#{student.id}"}
              class="flex min-h-11 items-center justify-between gap-3 py-1.5 pl-4 transition-colors hover:bg-sunk"
            >
              <span class="font-display text-lg text-ink">{student.display_name}</span>
              <.pill :if={!student.active} tone="quiet">停用</.pill>
            </.link>
          </li>
        </ul>
      </.section>
    </Layouts.app>
    """
  end
end
