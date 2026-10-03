#!/usr/bin/env elixir
# Real Teacher chat turns for schedule tasks (spec §8 slice 3).
#
#     mix ecto.migrate
#     source .env.dev && mix run priv/scripts/line_real_schedule.exs
#
# Uses Anthropic + Line.Client.Mock. Seeds SMOKE schedule data, runs three
# Conversation turns (cancel without reason, cancel with reason, style change).

import Ecto.Query

alias Ganesha.{Assistant, Catalog, Clock, People, Repo, Roster, Sales, Studio}
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

teacher_id = "Usmokesched0000000000000000"

cleanup = fn ->
  smoke_slot_ids = from(s in Studio.Slot, where: like(s.label, "SMOKE%"), select: s.id)

  session_ids =
    from(s in Studio.Session, where: s.slot_id in subquery(smoke_slot_ids), select: s.id)

  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  thread_ids = from(t in Thread, where: t.source_id == ^teacher_id, select: t.id)

  Repo.delete_all(from(c in Roster.Credit, where: c.origin_session_id in subquery(session_ids)))
  Repo.delete_all(
    from(a in Roster.Attendance,
      where: a.session_id in subquery(session_ids) or a.student_id in subquery(student_ids)
    )
  )

  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))
  Repo.delete_all(from(s in Studio.Session, where: s.id in subquery(session_ids)))
  Repo.delete_all(from(sl in Studio.Slot, where: like(sl.label, "SMOKE%")))
  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id == ^teacher_id))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))
end

run_turn = fn thread, text ->
  IO.puts("\nTeacher: #{text}\n")
  {:ok, _} = Assistant.append_message(thread, "user", text, nil)

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

      {thread, turn, drafts}

    {:error, reason} ->
      IO.puts("Agent failed: #{inspect(reason)}")
      System.halt(1)
  end
end

next_weekday_on_or_after = fn %Date{} = from, weekday ->
  ahead = rem(weekday - Date.day_of_week(from) + 7, 7)
  ahead = if ahead == 0, do: 7, else: ahead
  Date.add(from, ahead)
end

cleanup.()

try do
  today = Clock.today()
  weekday = Date.day_of_week(today)
  taken = Repo.all(from s in Studio.Slot, where: s.weekday == ^weekday, select: s.start_time)

  start_time =
    0..287
    |> Enum.map(&Time.add(~T[00:00:00], &1 * 5 * 60))
    |> Enum.find(&(&1 not in taken))

  if is_nil(start_time) do
    IO.puts("No free slot time left for weekday #{weekday}; pick another day manually.")
    System.halt(1)
  end

  {:ok, slot} =
    Studio.create_slot(%{
      weekday: weekday,
      start_time: start_time,
      end_time: Time.add(start_time, 75 * 60),
      default_style: "Hatha",
      label: "SMOKE 基礎"
    })

  cancel_date = next_weekday_on_or_after.(today, weekday)
  style_date = Date.add(cancel_date, 7)

  {:ok, session} =
    Studio.create_session(%{
      slot_id: slot.id,
      date: cancel_date,
      style: "Hatha",
      state: "scheduled"
    })

  {:ok, style_session} =
    Studio.create_session(%{
      slot_id: slot.id,
      date: style_date,
      style: "Hatha",
      state: "scheduled"
    })

  {:ok, student} = People.create_student(%{display_name: "SMOKE 蘭子"})

  {:ok, package} =
    Catalog.create_package(%{name: "SMOKE 月課程", kind: "monthly", price_per_class: 400})

  {:ok, purchase} =
    Sales.create_purchase(%{
      student_id: student.id,
      package_id: package.id,
      slot_id: slot.id,
      list_price: 2000
    })

  {:ok, _} = Roster.enroll(session, student, purchase)

  {:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
  {:ok, thread} = Assistant.set_locale(thread, "zh-TW")

  cancel_day = "#{cancel_date.month}/#{cancel_date.day}"

  {thread, _turn1, drafts1} =
    run_turn.(thread, "SMOKE 把 #{cancel_day} 那堂基礎課停掉")

  if Enum.any?(drafts1, &(&1.kind == "cancel_session" and &1.state == "pending")) do
    IO.puts(
      "\n(Warning: model proposed cancel without a stated reason — check parsed.reason)\n"
    )
  end

  {thread, _turn2, drafts2} =
    run_turn.(thread, "SMOKE 停課，原因是颱風假，session #{session.id}")

  case Enum.find(drafts2, &(&1.kind == "cancel_session" and &1.state == "pending")) do
    %Draft{} = draft ->
      case Assistant.confirm_draft(draft, "line:teacher") do
        {:ok, _} ->
          IO.puts("Confirmed cancel_session draft.")

          if Studio.get_session!(session.id).state != "cancelled" do
            IO.puts("Session was not cancelled after confirm.")
            System.halt(1)
          end

        other ->
          IO.puts("confirm_draft failed: #{inspect(other)}")
          System.halt(1)
      end

    nil ->
      IO.puts("Expected a pending cancel_session Draft on the second turn")
      System.halt(1)
  end

  {_thread, _turn3, drafts3} =
    run_turn.(thread, "SMOKE 把 session #{style_session.id} 的課型改成流動")

  IO.inspect(Enum.map(drafts3, & &1.kind), label: "draft kinds on style turn")

  case Enum.find(drafts3, &(&1.kind == "set_session_style")) do
    %Draft{} = style_draft ->
      IO.puts("set_session_style draft state=#{style_draft.state}")

    nil ->
      IO.puts("(No set_session_style draft on the style turn — model may have asked or replied only)")
  end

  IO.puts("\nDone — schedule real-model run finished.")
after
  cleanup.()
end
