defmodule Ganesha.Assistant.Tasks.PendingDrafts do
  @moduledoc """
  Lookup task `pending_drafts` (spec §3.1 #22): every pending Draft, from any
  chat, shown to the teacher as the turn's Draft carousel. Its answer carries
  the Drafts' ids as `draft_ids`, which the agent adds to the Turn, so
  `Ganesha.Line.Reply` packs them like the Drafts a turn creates (≤ 12 cards,
  the rest counted in the text). Teacher chat only: a Draft card's buttons
  only work for the teacher anyway (spec §6.3).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Assistant

  @impl true
  def name, do: "pending_drafts"

  @impl true
  def kind, do: :lookup

  @impl true
  def tool do
    %{
      description: """
      List every Draft still waiting for the teacher to confirm or discard, from this \
      chat and from the group. Their Draft cards are always shown under your reply, \
      oldest first. Use it when she asks what is waiting (待確認草稿) or needs a \
      pending Draft's id.\
      """,
      input_schema: %{type: "object", properties: %{}}
    }
  end

  @impl true
  def answer(_input, ctx) do
    drafts = Assistant.list_pending_drafts()
    {:ok, %{data: data(drafts, ctx.locale), draft_ids: Enum.map(drafts, & &1.id)}}
  end

  defp data([], _locale), do: "No Drafts are pending."

  defp data(drafts, locale) do
    lines = Enum.map(drafts, &"##{&1.id} #{Assistant.draft_summary(&1, locale)}")
    Enum.join(["#{length(drafts)} pending, shown to the teacher as cards:" | lines], "\n")
  end
end
