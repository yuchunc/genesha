defmodule Ganesha.Assistant.Tasks.UnblockAccount do
  @moduledoc """
  `unblock_account` (spec 2026-10-05-line-group-blocklist-design.md §3): read
  a blocked group or sender again. Teacher chat only; applies through
  `Ganesha.Line.unblock_account/2` on Confirm (ADR 0001).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Line

  @kinds ~w(group sender)

  @impl true
  def name, do: "unblock_account"

  @impl true
  def kind, do: :change

  @impl true
  def tool do
    %{
      description: """
      Read a blocked LINE group, or a blocked person, again (解除封鎖). This only proposes \
      a Draft; it takes effect when the teacher taps Confirm. Take kind and line_id from \
      the Blocked list in listening.\
      """,
      input_schema: %{
        type: "object",
        properties: %{
          kind: %{type: "string", enum: @kinds},
          line_id: %{type: "string"}
        },
        required: ["kind", "line_id"]
      }
    }
  end

  @impl true
  def propose(%{"kind" => kind, "line_id" => line_id}, _ctx)
      when kind in @kinds and is_binary(line_id) do
    case Line.get_blocked_account(kind, line_id) do
      nil ->
        {:error, "#{line_id} is not blocked as a #{kind}. Call listening for the Blocked list."}

      blocked ->
        {:ok,
         %{
           student_id: nil,
           parsed: %{"kind" => kind, "line_id" => line_id, "label" => blocked.label}
         }}
    end
  end

  def propose(_input, _ctx),
    do: {:error, ~s(kind must be "group" or "sender", and line_id an id from listening)}

  @impl true
  def apply(%{"kind" => kind, "line_id" => line_id}, _confirmed_by) do
    with :ok <- Line.unblock_account(kind, line_id), do: {:ok, {nil, nil}}
  end

  @impl true
  def summary(%{"kind" => "sender", "label" => label}, "en"),
    do: "Unblock #{label}: their group messages will be read again"

  def summary(%{"kind" => "sender", "label" => label}, _locale),
    do: "解除封鎖 #{label}：之後會再讀取這個人在群組中的訊息"

  def summary(%{"kind" => "group", "label" => label}, "en"),
    do: ~s(Unblock group "#{label}": read this group again)

  def summary(%{"kind" => "group", "label" => label}, _locale),
    do: "解除封鎖群組「#{label}」：之後會再讀取這個群組"
end
