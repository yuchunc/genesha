defmodule Ganesha.Assistant.Tasks.AskTeacher do
  @moduledoc """
  Control tool `ask_teacher` (spec §2 rule 5, §3.2): when the model cannot
  decide, it asks with 2–13 options of at most 20 characters. The options
  become quick-reply buttons whose text comes back as her next message.
  """
  @behaviour Ganesha.Assistant.Task

  @max_label 20

  @impl true
  def name, do: "ask_teacher"

  @impl true
  def kind, do: :control

  @impl true
  def tool do
    %{
      description: """
      Ask the teacher to choose when you cannot decide on your own, for example two \
      students named Amy or two Tuesday classes. Each option becomes a button; her tap \
      comes back as her next message. After calling this, end your turn with the question \
      itself as your reply.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          question: %{type: "string"},
          options: %{
            type: "array",
            items: %{type: "string", maxLength: @max_label},
            minItems: 2,
            maxItems: 13
          }
        },
        required: ["question", "options"]
      }
    }
  end

  @impl true
  def answer(%{"question" => question, "options" => options}, _ctx)
      when is_binary(question) and is_list(options) do
    if String.trim(question) != "" and valid_options?(options) do
      {:ok,
       %{
         data:
           "Buttons shown to the teacher: #{Enum.join(options, " / ")}. " <>
             "End your turn now with the question as your reply.",
         choices: options
       }}
    else
      {:error, invalid()}
    end
  end

  def answer(_input, _ctx), do: {:error, invalid()}

  defp valid_options?(options) do
    length(options) in 2..13 and
      Enum.all?(options, &(is_binary(&1) and &1 != "" and String.length(&1) <= @max_label))
  end

  defp invalid, do: "ask_teacher needs a question and 2–13 options of 1–20 characters each"
end
