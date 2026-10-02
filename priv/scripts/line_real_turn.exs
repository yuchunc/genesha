#!/usr/bin/env elixir
# One real Teacher chat turn through Ganesha.Assistant.Conversation against
# the real model (spec §8: every slice ends with a real Sonnet 5.5 run).
#
#     mix ecto.migrate
#     source .env.dev && mix run priv/scripts/line_real_turn.exs "SMOKE 小美今天轉了 3200"
#
# Uses the dev Anthropic provider (ANTHROPIC_API_KEY; ANTHROPIC_MODEL or
# claude-sonnet-5-5) and Ganesha.Line.Client.Mock, so nothing reaches LINE.
# Prints the Turn, its Drafts, the LINE messages Reply.build/3 packs from it
# and the history line. Rows it creates are prefixed SMOKE and removed again.

import Ecto.Query

alias Ganesha.{Assistant, Catalog, People, Repo, Sales}
alias Ganesha.Assistant.{Conversation, Draft, Message, Thread}
alias Ganesha.Line.Reply

Logger.configure(level: :warning)
Application.put_env(:ganesha, :line_client, Ganesha.Line.Client.Mock)

provider = Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider)

api_key =
  :ganesha
  |> Application.get_env(Ganesha.Assistant.Provider.Anthropic, [])
  |> Keyword.get(:api_key, "")

if provider != Ganesha.Assistant.Provider.Anthropic or api_key == "" do
  IO.puts("Needs the dev Anthropic provider and ANTHROPIC_API_KEY: run `source .env.dev` first.")
  System.halt(1)
end

teacher_id = "Usmokerealturn00000000000000"
text = List.first(System.argv()) || "SMOKE 小美今天轉了 3200，是月課程的"

cleanup = fn ->
  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  thread_ids = from(t in Thread, where: t.source_id == ^teacher_id, select: t.id)

  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id == ^teacher_id))
  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))
end

cleanup.()

{:ok, student} = People.create_student(%{display_name: "SMOKE 小美"})

{:ok, package} =
  Catalog.create_package(%{
    name: "SMOKE 月課程",
    kind: "monthly",
    price_per_class: 400,
    included_makeups: 1
  })

{:ok, _purchase} =
  Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 3200})

{:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, thread} = Assistant.set_locale(thread, "zh-TW")
{:ok, _} = Assistant.append_message(thread, "user", text, nil)

IO.puts("Teacher: #{text}\n")

case Conversation.run_turn(thread) do
  {:ok, turn} ->
    drafts = Assistant.get_drafts(turn.draft_ids)

    IO.puts("== Turn")
    IO.inspect(turn, pretty: true, charlists: :as_lists)

    IO.puts("\n== Drafts")

    Enum.each(
      drafts,
      &IO.inspect(Map.take(&1, [:id, :kind, :state, :student_id, :parsed]), pretty: true)
    )

    IO.puts("\n== LINE messages (Reply.build/3)")
    IO.puts(Jason.encode!(Reply.build(turn, drafts, "zh-TW"), pretty: true))

    IO.puts("\n== History line (Reply.history_text/3)")
    IO.puts(Reply.history_text(turn, drafts, "zh-TW") || "(none)")

    cleanup.()

  {:error, reason} ->
    cleanup.()
    IO.puts("Agent.run/4 failed: #{inspect(reason)}")
    System.halt(1)
end
