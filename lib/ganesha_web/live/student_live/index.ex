defmodule GaneshaWeb.StudentLive.Index do
  use GaneshaWeb, :live_view

  alias Ganesha.{People, Reporting}
  alias Ganesha.People.Student

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, to_form(People.change_student(%Student{})))
     |> load_students()}
  end

  defp load_students(socket) do
    outstanding = Reporting.outstanding_map()
    {active, inactive} = Enum.split_with(People.list_students(), & &1.active)

    socket
    |> stream(
      :active_students,
      active |> Enum.map(&with_outstanding(&1, outstanding)) |> rank_by_urgency(),
      dom_id: &"student-#{&1.student.id}",
      reset: true
    )
    |> stream(
      :inactive_students,
      inactive |> Enum.map(&with_outstanding(&1, outstanding)) |> rank_by_urgency(),
      dom_id: &"student-#{&1.student.id}",
      reset: true
    )
    |> assign(:active_count, length(active))
    |> assign(:inactive_count, length(inactive))
    |> assign(:total_outstanding, outstanding |> Map.values() |> Enum.sum())
    |> assign(:owing_count, outstanding |> Map.values() |> Enum.count(&(&1 > 0)))
  end

  # Owing students first, largest balance first — mirrors the 帳 ledger view's
  # "outstanding by student, ranked". Settled students fall back to name order,
  # since there is no money question left to answer for them.
  defp rank_by_urgency(entries) do
    Enum.sort_by(entries, &{&1.outstanding <= 0, -&1.outstanding, &1.student.display_name})
  end

  defp with_outstanding(student, outstanding) do
    %{student: student, outstanding: Map.get(outstanding, student.id, 0)}
  end

  @impl true
  def handle_event("save", %{"student" => params}, socket) do
    case People.create_student(params) do
      {:ok, student} ->
        {:noreply,
         socket
         |> stream_insert(:active_students, with_outstanding(student, %{}), at: 0)
         |> update(:active_count, &(&1 + 1))
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

      <p id="outstanding-summary" data-amount={@total_outstanding} class="mt-1">
        <.money
          amount={@total_outstanding}
          size="lg"
          tone={if @total_outstanding > 0, do: "turmeric", else: "celadon"}
          label={if @owing_count > 0, do: "#{@owing_count} 位學生未收款", else: "所有學生款項已收齊"}
        />
      </p>

      <.section title="新增學生">
        <.form for={@form} id="student-form" phx-submit="save" class="flex items-start gap-2">
          <div class="flex-1">
            <.input field={@form[:display_name]} type="text" placeholder="姓名" />
          </div>
          <.button variant="primary">加入學生</.button>
        </.form>
      </.section>

      <.section title="在班學生" count={@active_count}>
        <.empty :if={@active_count == 0} id="no-active-students">
          目前沒有在班學生。用上面的表單加入第一位。
        </.empty>

        <ul :if={@active_count > 0} id="active-students" phx-update="stream" class="space-y-1">
          <.student_row
            :for={{dom_id, entry} <- @streams.active_students}
            dom_id={dom_id}
            entry={entry}
          />
        </ul>
      </.section>

      <.section :if={@inactive_count > 0} title="已停用" count={@inactive_count}>
        <ul id="inactive-students" phx-update="stream" class="space-y-1">
          <.student_row
            :for={{dom_id, entry} <- @streams.inactive_students}
            dom_id={dom_id}
            entry={entry}
          />
        </ul>
      </.section>
    </Layouts.app>
    """
  end

  attr :dom_id, :string, required: true
  attr :entry, :map, required: true

  defp student_row(assigns) do
    ~H"""
    <li
      id={@dom_id}
      class={[
        "border-l-[3px] pl-4",
        if(@entry.outstanding > 0, do: "border-turmeric", else: "border-rule")
      ]}
    >
      <.link
        navigate={~p"/students/#{@entry.student.id}"}
        class="flex min-h-11 items-center justify-between gap-3 py-1.5 transition-colors hover:bg-sunk"
      >
        <span class="font-display text-lg text-ink">{@entry.student.display_name}</span>
        <.money :if={@entry.outstanding > 0} amount={@entry.outstanding} tone="turmeric" size="sm" />
      </.link>
    </li>
    """
  end
end
