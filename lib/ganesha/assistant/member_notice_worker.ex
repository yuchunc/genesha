defmodule Ganesha.Assistant.MemberNoticeWorker do
  @moduledoc """
  Tells every teacher, in her own language, that a LINE group member became a
  Student (`created`, `linked`) or might be one (`unsure`), with undo buttons
  (spec 2026-10-19-november-launch-design.md §2). Each teacher whose push
  succeeded also gets 「[通知] …」 in her Teacher chat history, so the model
  knows what she saw. As in `Ganesha.Assistant.DraftNotifier`, the job fails,
  and Oban retries it, only when no teacher's push succeeded.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ganesha.Assistant
  alias Ganesha.Line.{Cards, Client, Labels}
  alias Ganesha.People.Student

  @max_candidates 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    results = Enum.map(Ganesha.Line.teacher_ids(), &notify(&1, args))

    if :ok in results,
      do: :ok,
      else: Enum.find(results, {:error, :no_teachers}, &match?({:error, _}, &1))
  end

  defp notify(teacher_id, args) do
    locale = Assistant.teacher_locale(teacher_id)
    {alt_text, message} = message(args, locale)

    with :ok <- line_client().push(teacher_id, [message]) do
      {:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
      line = "[#{Labels.t(:tag_notice, locale)}] #{alt_text}"
      {:ok, _} = Assistant.append_message(thread, "assistant", line, nil)
      :ok
    end
  end

  @doc """
  The job args for a `Ganesha.People.resolve_line_member/2` result that needs
  a notice: string keys, the Student for `created`/`linked`, up to three
  candidates and the count beyond them for `unsure`.
  """
  @spec args(
          {:created | :linked, Student.t()} | {:unsure, [Student.t()]},
          String.t(),
          String.t()
        ) :: map()
  def args({kind, %Student{} = student}, line_user_id, display_name)
      when kind in [:created, :linked] do
    line_user_id
    |> base_args(kind, display_name)
    |> Map.merge(%{"student_id" => student.id, "student_name" => student.display_name})
  end

  def args({:unsure, candidates}, line_user_id, display_name) when is_list(candidates) do
    {shown, rest} = Enum.split(candidates, @max_candidates)

    line_user_id
    |> base_args(:unsure, display_name)
    |> Map.merge(%{
      "candidates" => Enum.map(shown, &%{"id" => &1.id, "name" => &1.display_name}),
      "more" => length(rest)
    })
  end

  defp base_args(line_user_id, kind, display_name) do
    %{
      "kind" => Atom.to_string(kind),
      "line_user_id" => line_user_id,
      "display_name" => display_name
    }
  end

  # The alt text is the notice's first text line.
  defp message(args, locale) do
    bubble = Cards.member_notice(args, locale)
    [%{text: alt_text} | _] = bubble.body.contents
    {alt_text, Client.flex_message(alt_text, bubble)}
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
