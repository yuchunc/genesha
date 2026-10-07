#!/usr/bin/env elixir
# Real Sonnet 5.5 runs for the six lookup tasks (spec §8, slice 2).
#
#     mix run priv/scripts/line_real_questions.exs
#
# Uses the dev Anthropic provider (ANTHROPIC_API_KEY from .env.dev, loaded by
# mise.toml) and Line.Client.Mock — nothing reaches users.
# For LINE Flex validation against the real API, run `mix line.validate_cards`.
#
# Seeds a small SMOKE studio (a Slot, two Sessions, two students, purchases, a
# payment and a makeup Credit), asks the six questions in one Teacher chat and
# prints, per turn, which tasks the model called, the reply text, and the LINE
# messages Reply.build/3 packs. Every row it creates is removed again, whether
# the run succeeds or fails.

import Ecto.Query

alias Ganesha.{Assistant, Catalog, Clock, People, Repo, Roster, Sales, Studio}
alias Ganesha.Assistant.{Conversation, Digest, Draft, Message, Thread}
alias Ganesha.Line.Reply

Logger.configure(level: :warning)
Application.put_env(:ganesha, :line_client, Ganesha.Line.Client.Mock)

provider = Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider)

api_key =
  :ganesha
  |> Application.get_env(Ganesha.Assistant.Provider.Anthropic, [])
  |> Keyword.get(:api_key, "")

if provider != Ganesha.Assistant.Provider.Anthropic or api_key == "" do
  IO.puts("Needs the dev Anthropic provider and ANTHROPIC_API_KEY in .env.dev (loaded by mise.toml).")
  System.halt(1)
end

teacher_id = "Usmokequestions00000000000000"

cleanup = fn ->
  student_ids = from(s in People.Student, where: like(s.display_name, "SMOKE%"), select: s.id)

  purchase_ids =
    from(p in Sales.Purchase, where: p.student_id in subquery(student_ids), select: p.id)

  slot_ids = from(s in Studio.Slot, where: like(s.label, "SMOKE%"), select: s.id)
  session_ids = from(s in Studio.Session, where: s.slot_id in subquery(slot_ids), select: s.id)
  thread_ids = from(t in Thread, where: t.source_id == ^teacher_id, select: t.id)

  Repo.delete_all(from(d in Digest, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(d in Draft, where: d.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(m in Message, where: m.thread_id in subquery(thread_ids)))
  Repo.delete_all(from(t in Thread, where: t.source_id == ^teacher_id))

  Repo.delete_all(
    from(c in Roster.Credit,
      where:
        c.student_id in subquery(student_ids) or c.origin_purchase_id in subquery(purchase_ids) or
          c.origin_session_id in subquery(session_ids)
    )
  )

  Repo.delete_all(
    from(a in Roster.Attendance,
      where: a.student_id in subquery(student_ids) or a.session_id in subquery(session_ids)
    )
  )

  Repo.delete_all(from(p in Sales.Payment, where: p.purchase_id in subquery(purchase_ids)))
  Repo.delete_all(from(p in Sales.Purchase, where: p.student_id in subquery(student_ids)))
  Repo.delete_all(from(s in Studio.Session, where: s.id in subquery(session_ids)))
  Repo.delete_all(from(s in Studio.Slot, where: like(s.label, "SMOKE%")))
  Repo.delete_all(from(s in People.Student, where: like(s.display_name, "SMOKE%")))
  Repo.delete_all(from(p in Catalog.Package, where: like(p.name, "SMOKE%")))
end

seed = fn ->
  today = Clock.today()
  first = Date.add(today, 4)
  weekday = Date.day_of_week(first)
  taken = Repo.all(from s in Studio.Slot, where: s.weekday == ^weekday, select: s.start_time)

  # Slots are unique on weekday + start_time: take the first free time from 19:00.
  start_time =
    0..59
    |> Enum.map(&Time.add(~T[19:00:00], &1 * 5 * 60))
    |> Enum.find(&(&1 not in taken))

  {:ok, slot} =
    Studio.create_slot(%{
      weekday: weekday,
      start_time: start_time,
      end_time: Time.add(start_time, 75 * 60),
      default_style: "Hatha",
      label: "SMOKE 基礎"
    })

  {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: first, style: "Hatha"})

  {:ok, later} =
    Studio.create_session(%{slot_id: slot.id, date: Date.add(first, 7), style: "Hatha"})

  {:ok, monthly} =
    Catalog.create_package(%{
      name: "SMOKE 月課程",
      kind: "monthly",
      price_per_class: 400,
      included_makeups: 1
    })

  {:ok, drop_in} =
    Catalog.create_package(%{name: "SMOKE 單堂", kind: "drop_in", price_per_class: 400})

  {:ok, mei} = People.create_student(%{display_name: "SMOKE 小美"})
  {:ok, ming} = People.create_student(%{display_name: "SMOKE 阿明"})

  {:ok, mei_purchase} =
    Sales.create_purchase(%{
      student_id: mei.id,
      package_id: monthly.id,
      slot_id: slot.id,
      list_price: 3200
    })

  {:ok, ming_purchase} =
    Sales.create_purchase(%{student_id: ming.id, package_id: drop_in.id, list_price: 400})

  {:ok, _} = Roster.enroll(session, mei, mei_purchase)
  {:ok, _} = Roster.enroll(later, mei, mei_purchase)
  {:ok, _} = Roster.add_drop_in(session, ming, ming_purchase)
  {:ok, _credits} = Roster.mint_package_credits(mei_purchase)

  {:ok, payment} =
    Sales.record_payment(%{
      purchase_id: mei_purchase.id,
      amount: 1200,
      method: "line_bank",
      paid_on: today
    })

  {:ok, _} = Sales.confirm_payment(payment, "smoke:questions")

  session
end

# Which tasks the model called in this turn, from the stored assistant rounds.
calls_since = fn thread, after_id ->
  thread
  |> Assistant.list_messages()
  |> Enum.filter(
    &(&1.id > after_id and &1.role == "assistant" and &1.tool_calls not in [nil, []])
  )
  |> Enum.flat_map(& &1.tool_calls)
  |> Enum.map(&{&1["name"], &1["input"]})
end

message_kind = fn
  %{type: "text"} -> "text"
  %{type: "flex", contents: %{type: type}, altText: alt} -> "flex #{type} (#{alt})"
end

ask = fn thread, text, expected ->
  {:ok, user} = Assistant.append_message(thread, "user", text, nil)
  IO.puts("\n== Teacher: #{text}")

  case Conversation.run_turn(thread) do
    {:ok, turn} ->
      drafts = Assistant.get_drafts(turn.draft_ids)
      calls = calls_since.(thread, user.id)
      history = Reply.history_text(turn, drafts, "zh-TW")

      # What Conversation.handle_message/3 does after replying, so later
      # questions see which Draft cards she was shown.
      if history, do: {:ok, _} = Assistant.append_to_message(turn.reply_message_id, history)

      for {name, input} <- calls do
        IO.puts("call: #{name} #{Jason.encode!(input)}")
      end

      IO.puts("drafts: #{length(drafts)}")

      turn
      |> Reply.build(drafts, "zh-TW")
      |> Enum.each(fn
        %{type: "text", text: reply} -> IO.puts("reply text:\n" <> reply)
        message -> IO.puts("message: " <> message_kind.(message))
      end)

      IO.puts("history: " <> (history || "(no Draft history)"))

      called? = Enum.any?(calls, fn {name, _input} -> name == expected end)
      reply = turn.text || ""

      # Card lines are the system's (prompt rule 6); the model must not write its own.
      fabricated = reply |> String.split("\n") |> Enum.filter(&(&1 =~ ~r/^\[[^\]]+\] /))
      markdown? = reply =~ "**" or reply =~ ~r/^\s*#/m

      cond do
        not called? ->
          IO.puts("=> MISS #{expected} (not called)")
          {:miss, text}

        fabricated != [] ->
          IO.puts("=> MISS #{expected}: model wrote card lines #{inspect(fabricated)}")
          {:fabricated, text}

        markdown? ->
          IO.puts("=> MISS #{expected}: the reply uses markdown")
          {:markdown, text}

        true ->
          IO.puts("=> OK #{expected}, plain text with no card lines")
          :ok
      end

    {:error, reason} ->
      IO.puts("failed: #{inspect(reason)}")
      {:error, text}
  end
end

cleanup.()

results =
  try do
    session = seed.()
    {:ok, thread} = Assistant.get_or_create_thread("teacher", teacher_id)
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")

    [
      {"下一堂課是什麼時候？誰會來？", "next_session"},
      {"幫我看這個月的課表", "month_schedule"},
      {"#{session.date.month}/#{session.date.day} 那堂 SMOKE 基礎班的名單給我", "session_roster"},
      {"SMOKE 小美欠多少？她最近的課和補課券呢？", "student_summary"},
      {"這個月收入多少？還有誰沒付清？", "month_money"},
      {"現在還有哪些補課券沒用？", "open_credits"}
    ]
    |> Enum.map(fn {text, expected} -> ask.(thread, text, expected) end)
  after
    cleanup.()
  end

case Enum.reject(results, &(&1 == :ok)) do
  [] ->
    IO.puts(
      "\nAll six questions called their lookup and answered in plain text. " <>
        "SMOKE rows removed."
    )

  problems ->
    IO.puts("\n#{length(problems)} question(s) need attention: #{inspect(problems)}")
    System.halt(1)
end
