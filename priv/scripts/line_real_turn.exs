#!/usr/bin/env elixir
# One real Teacher chat turn through Ganesha.Assistant.Conversation against
# the real model (spec §8: every slice ends with a real Sonnet 5.5 run).
#
#     mix ecto.migrate
#     source .env.dev && mix run priv/scripts/line_real_turn.exs
#     source .env.dev && mix run priv/scripts/line_real_turn.exs enroll
#     source .env.dev && mix run priv/scripts/line_real_turn.exs no_show
#
# Uses the dev Anthropic provider (ANTHROPIC_API_KEY; ANTHROPIC_MODEL or
# claude-sonnet-5-5) and Ganesha.Line.Client.Mock, so nothing reaches LINE.

import Ecto.Query

alias Ganesha.{Assistant, Catalog, Enrolling, People, Repo, Sales, Studio}
alias Ganesha.Assistant.{Conversation, Draft, Message, Thread}
alias Ganesha.Line.Reply
alias Ganesha.Roster.Attendance
alias Ganesha.Roster.Credit
alias Ganesha.Studio.Session

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
scenario = List.first(System.argv()) || "payment"

cleanup = fn ->
  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  thread_ids = from(t in Thread, where: t.source_id == ^teacher_id, select: t.id)

  smoke_slot_ids = from(s in Studio.Slot, where: like(s.label, "SMOKE%"), select: s.id)

  smoke_session_ids =
    from(s in Session, where: s.slot_id in subquery(smoke_slot_ids), select: s.id)

  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id == ^teacher_id))
  Repo.delete_all(from(c in Credit, where: c.student_id in subquery(student_ids)))
  Repo.delete_all(from(a in Attendance, where: a.student_id in subquery(student_ids)))
  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))
  Repo.delete_all(from(s in Session, where: s.id in subquery(smoke_session_ids)))
  Repo.delete_all(from(s in Studio.Slot, where: like(s.label, "SMOKE%")))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))
end

cleanup.()

text =
  case scenario do
    "enroll" ->
      {:ok, student} = People.create_student(%{display_name: "SMOKE 阿花"})

      {:ok, slot} =
        Studio.create_slot(%{
          weekday: 3,
          start_time: ~T[19:00:00],
          end_time: ~T[20:15:00],
          default_style: "SMOKE Hatha",
          label: "SMOKE 基礎"
        })

      {:ok, _sessions} = Studio.generate_month(slot, ~D[2026-10-01])

      {:ok, package} =
        Catalog.create_package(%{
          name: "SMOKE 月課程",
          kind: "monthly",
          price_per_class: 400,
          included_makeups: 1
        })

      "SMOKE 幫 #{student.display_name} 報名 #{slot.label} 2026-10 月課程 #{package.name}（slot #{slot.id} package #{package.id}）"

    "no_show" ->
      {:ok, student} = People.create_student(%{display_name: "SMOKE 阿花"})

      {:ok, slot} =
        Studio.create_slot(%{
          weekday: Date.day_of_week(Date.add(Ganesha.Clock.today(), -2)),
          start_time: ~T[19:00:00],
          end_time: ~T[20:15:00],
          default_style: "SMOKE Hatha",
          label: "SMOKE 晚課"
        })

      {:ok, session} =
        Studio.create_session(%{
          slot_id: slot.id,
          date: Date.add(Ganesha.Clock.today(), -2),
          style: "SMOKE Hatha"
        })

      {:ok, package} =
        Catalog.create_package(%{name: "SMOKE 單堂", kind: "drop_in", price_per_class: 400})

      {:ok, _} = Enrolling.add_one_off(session, student, package, [])

      "SMOKE #{student.display_name} #{Date.to_iso8601(session.date)} 那堂沒來，記缺席（session #{session.id}）"

    "payment" ->
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

      "SMOKE 小美今天轉了 3200，是月課程的"

    other ->
      cleanup.()
      IO.puts("Unknown scenario #{inspect(other)}; use payment, enroll, or no_show")
      System.halt(1)
  end

{:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
{:ok, thread} = Assistant.set_locale(thread, "zh-TW")
{:ok, _} = Assistant.append_message(thread, "user", text, nil)

IO.puts("Scenario: #{scenario}\nTeacher: #{text}\n")

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
