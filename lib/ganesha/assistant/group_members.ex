defmodule Ganesha.Assistant.GroupMembers do
  @moduledoc """
  LINE group members as Students (spec 2026-10-19-november-launch-design.md
  §1-2): resolves a member and, when that made or may make them a Student,
  enqueues the teachers' notice in the same transaction.
  """

  alias Ganesha.{Line, People, Repo}
  alias Ganesha.Assistant.MemberNoticeWorker

  @doc """
  Resolves a group member with `Ganesha.People.resolve_line_member/2`, or
  `:skipped` for a teacher. A `created`, `linked` or `unsure` result enqueues
  one `MemberNoticeWorker` job in the same transaction.
  """
  @spec resolve(String.t(), String.t()) :: People.resolution() | :skipped
  def resolve(line_user_id, display_name)
      when is_binary(line_user_id) and is_binary(display_name) do
    if Line.teacher?(line_user_id) do
      :skipped
    else
      {:ok, resolution} =
        Repo.transaction(fn ->
          resolution = People.resolve_line_member(line_user_id, display_name)
          notify(resolution, line_user_id, String.trim(display_name))
          resolution
        end)

      resolution
    end
  end

  defp notify({kind, _} = resolution, line_user_id, display_name)
       when kind in [:created, :linked, :unsure] do
    {:ok, _job} =
      resolution
      |> MemberNoticeWorker.args(line_user_id, display_name)
      |> MemberNoticeWorker.new()
      |> Oban.insert()

    :ok
  end

  defp notify(_resolution, _line_user_id, _display_name), do: :ok
end
