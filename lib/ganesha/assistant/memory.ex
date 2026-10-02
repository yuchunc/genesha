defmodule Ganesha.Assistant.Memory do
  @moduledoc """
  What the model remembers of a chat (spec §6.4).

  - A counted message is a `user` message, or an `assistant` message with no
    tool calls.
  - Level 1: the last 30 counted messages and every message after the oldest
    of them; when more than 30 counted messages were sent today
    (Asia/Taipei), all of today's, up to 100 counted. The window always starts
    at a `user` message. Student chats: the last 30 counted only.
  - Level 3: weekly digests whose `period_end` is at least 15 days before
    today and whose `period_start` is within 90 days.
  - Level 2: daily digests after the newest Level 3 week (or within the last
    14 days when there is none), up to and including the date of the oldest
    Level 1 message.
  """

  import Ecto.Query

  alias Ganesha.{Clock, Repo}
  alias Ganesha.Assistant.{Digest, Message, Thread}

  @window 30
  @today_cap 100

  @spec history(Thread.t(), :teacher | :student, DateTime.t()) :: [Message.t()]
  def history(%Thread{} = thread, kind, %DateTime{} = now) when kind in [:teacher, :student] do
    case window_start(thread, kind, Clock.today(now)) do
      nil ->
        []

      %{id: start_id} ->
        Repo.all(
          from m in Message,
            where: m.thread_id == ^thread.id and m.id >= ^start_id,
            order_by: m.id
        )
    end
  end

  @spec summaries(Thread.t(), Date.t()) :: String.t() | nil
  def summaries(%Thread{} = thread, %Date{} = today) do
    weeks = weekly_digests(thread, today)
    days = daily_digests(thread, today, weeks)

    case weeks ++ days do
      [] -> nil
      digests -> Enum.map_join(digests, "\n\n", &render/1)
    end
  end

  # A counted message: `user`, or `assistant` with no tool calls.
  defp counted do
    dynamic(
      [m],
      m.role == "user" or
        (m.role == "assistant" and (is_nil(m.tool_calls) or m.tool_calls == ^[]))
    )
  end

  # The oldest counted message of the Level 1 window, or nil when the window
  # holds no user message.
  defp window_start(thread, kind, today) do
    counted =
      Repo.all(
        from m in Message,
          where: m.thread_id == ^thread.id,
          where: ^counted(),
          order_by: [desc: m.id],
          limit: @today_cap,
          select: %{id: m.id, role: m.role, inserted_at: m.inserted_at}
      )

    counted
    |> Enum.take(window_size(counted, kind, today))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.role != "user"))
    |> List.first()
  end

  defp window_size(_counted, :student, _today), do: @window

  defp window_size(counted, :teacher, today) do
    start = Clock.day_start_utc(today)
    sent_today = Enum.count(counted, &(DateTime.compare(&1.inserted_at, start) != :lt))
    max(sent_today, @window)
  end

  defp weekly_digests(thread, today) do
    ended_by = Date.add(today, -15)
    started_from = Date.add(today, -90)

    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == "weekly",
        where: d.period_end <= ^ended_by and d.period_start >= ^started_from,
        order_by: d.period_start
    )
  end

  defp daily_digests(thread, today, weeks) do
    after_date =
      case List.last(weeks) do
        nil -> Date.add(today, -15)
        week -> week.period_end
      end

    until = level1_start_date(thread, today) || today

    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == "daily",
        where: d.period_start > ^after_date and d.period_start <= ^until,
        order_by: d.period_start
    )
  end

  defp level1_start_date(thread, today) do
    case window_start(thread, :teacher, today) do
      nil -> nil
      %{inserted_at: inserted_at} -> Clock.to_taipei_date(inserted_at)
    end
  end

  defp render(%Digest{kind: "weekly"} = digest),
    do: "[#{digest.period_start} – #{digest.period_end}]\n#{digest.content}"

  defp render(%Digest{} = digest), do: "[#{digest.period_start}]\n#{digest.content}"
end
