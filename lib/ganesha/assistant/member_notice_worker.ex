defmodule Ganesha.Assistant.MemberNoticeWorker do
  @moduledoc """
  Tells every teacher, in her own language, that a LINE group member became a
  Student (`created`, `linked`) or might be one (`unsure`), with undo buttons
  (spec 2026-10-19-november-launch-design.md §2). As in
  `Ganesha.Assistant.DraftNotifier`, the job fails, and Oban retries it, only
  when no teacher's push succeeded.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ganesha.Assistant
  alias Ganesha.Line.{Cards, Client}
  alias Ganesha.People.Student

  @max_candidates 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    results =
      Enum.map(Ganesha.Line.teacher_ids(), fn teacher_id ->
        line_client().push(teacher_id, [message(args, Assistant.teacher_locale(teacher_id))])
      end)

    if :ok in results,
      do: :ok,
      else: Enum.find(results, {:error, :no_teachers}, &match?({:error, _}, &1))
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
    Client.flex_message(alt_text, bubble)
  end

  defp line_client, do: Application.get_env(:ganesha, :line_client, Ganesha.Line.Client)
end
