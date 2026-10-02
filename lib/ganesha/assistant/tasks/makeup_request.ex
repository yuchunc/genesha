defmodule Ganesha.Assistant.Tasks.MakeupRequest do
  @moduledoc """
  `makeup_request` (spec §3.1 #21): a student asked for a makeup. The Draft
  is acknowledged only — confirming marks it applied and books nothing; the
  teacher books the makeup herself.
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.People

  @impl true
  def name, do: "makeup_request"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Note that a student asked for a makeup class so the teacher can arrange it. \
      Confirming only acknowledges it; nothing is booked. Leave student_id out if you \
      cannot tell who it is.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          student_id: %{type: "integer"},
          note: %{type: "string", description: "What the student asked for, e.g. 想補 8/17 或 8/31"}
        },
        required: ["note"]
      }
    }
  end

  @impl true
  def propose(input, _ctx) do
    with {:ok, note} <- fetch_note(input["note"]),
         {:ok, student} <- fetch_student(input["student_id"]) do
      student_id = student && student.id

      {:ok,
       %{
         student_id: student_id,
         parsed: %{
           "note" => note,
           "student_id" => student_id,
           "student_name" => student && student.display_name
         }
       }}
    end
  end

  @impl true
  def apply(_parsed, _confirmed_by), do: {:ok, {nil, nil}}

  @impl true
  def describe(parsed, locale) do
    %{
      title: Enum.join(Enum.reject([title(locale), parsed["student_name"]], &is_nil/1), " "),
      lines: Enum.reject([parsed["note"]], &(&1 in [nil, ""])),
      changes: [],
      web_path: parsed["student_id"] && "/students/#{parsed["student_id"]}"
    }
  end

  defp fetch_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> {:error, missing_note()}
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_note(_note), do: {:error, missing_note()}

  defp missing_note, do: "makeup_request needs a note saying what the student asked for"

  defp fetch_student(nil), do: {:ok, nil}

  defp fetch_student(id) when is_integer(id) do
    case People.get_student(id) do
      nil ->
        {:error, "no student with id #{id}; use a student id from the snapshot, or leave it out"}

      student ->
        {:ok, student}
    end
  end

  defp fetch_student(_id), do: {:error, "student_id must be an integer id from the snapshot"}

  defp title("en"), do: "Makeup request"
  defp title(_locale), do: "補課需求"
end
