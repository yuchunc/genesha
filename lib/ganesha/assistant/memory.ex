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
  - Writing (`DigestWorker`, nightly): a daily digest for every day in the
    last 90 days with counted messages and no digest, then a weekly digest
    for every complete week in range, built from that week's daily digests.
  - Invalidation: unsend or edit of a Teacher chat message deletes the daily
    digest for that date and the weekly digest containing it.
  """

  import Ecto.Query

  require Logger

  alias Ganesha.{Clock, Repo}
  alias Ganesha.Assistant.{Digest, Message, Prompts, Thread}

  @window 30
  @today_cap 100
  @digest_days 90

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

  @spec write_missing_digests(Thread.t(), Date.t()) :: :ok
  def write_missing_digests(%Thread{} = thread, %Date{} = today) do
    first_day = Date.add(today, -@digest_days)
    last_day = Date.add(today, -1)
    locale = thread.locale || "zh-TW"

    written_days = digest_starts(thread, "daily", first_day)

    thread
    |> counted_by_day(first_day, today)
    |> Enum.reject(fn {day, _messages} -> MapSet.member?(written_days, day) end)
    |> Enum.each(fn {day, messages} ->
      write_digest(thread, locale, "daily", day, day, transcript(messages))
    end)

    written_weeks = digest_starts(thread, "weekly", first_day)

    first_day
    |> complete_weeks(last_day)
    |> Enum.reject(&MapSet.member?(written_weeks, &1))
    |> Enum.each(fn monday ->
      sunday = Date.add(monday, 6)

      case daily_texts(thread, monday, sunday) do
        [] ->
          :ok

        dailies ->
          write_digest(thread, locale, "weekly", monday, sunday, Enum.join(dailies, "\n\n"))
      end
    end)

    :ok
  end

  @spec invalidate_digests(integer(), Date.t()) :: :ok
  def invalidate_digests(thread_id, %Date{} = date) do
    Repo.delete_all(
      from d in Digest,
        where: d.thread_id == ^thread_id and d.kind == "daily" and d.period_start == ^date
    )

    Repo.delete_all(
      from d in Digest,
        where: d.thread_id == ^thread_id and d.kind == "weekly",
        where: d.period_start <= ^date and d.period_end >= ^date
    )

    :ok
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

  # Counted messages with text from [first_day, today), grouped by Asia/Taipei
  # date, oldest day first. An unsent message has no text and is left out.
  defp counted_by_day(thread, first_day, today) do
    Repo.all(
      from m in Message,
        where: m.thread_id == ^thread.id,
        where: ^counted(),
        where: not is_nil(m.content),
        where: m.inserted_at >= ^Clock.day_start_utc(first_day),
        where: m.inserted_at < ^Clock.day_start_utc(today),
        order_by: m.id
    )
    |> Enum.group_by(&Clock.to_taipei_date(&1.inserted_at))
    |> Enum.sort_by(fn {day, _messages} -> day end, Date)
  end

  defp transcript(messages) do
    Enum.map_join(messages, "\n", &"#{speaker(&1.role)}: #{&1.content}")
  end

  defp speaker("user"), do: "Teacher"
  defp speaker(_role), do: "Assistant"

  defp digest_starts(thread, kind, first_day) do
    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == ^kind and d.period_start >= ^first_day,
        select: d.period_start
    )
    |> MapSet.new()
  end

  # Mondays of the Monday–Sunday weeks lying wholly within [first_day, last_day].
  defp complete_weeks(first_day, last_day) do
    first_day
    |> Date.add(rem(8 - Date.day_of_week(first_day), 7))
    |> Stream.iterate(&Date.add(&1, 7))
    |> Enum.take_while(&(Date.compare(Date.add(&1, 6), last_day) != :gt))
  end

  defp daily_texts(thread, from, to) do
    Repo.all(
      from d in Digest,
        where: d.thread_id == ^thread.id and d.kind == "daily",
        where: d.period_start >= ^from and d.period_start <= ^to,
        order_by: d.period_start,
        select: {d.period_start, d.content}
    )
    |> Enum.map(fn {day, content} -> "[#{day}]\n#{content}" end)
  end

  # Digests use the digest prompt and no tools (spec §6.4). A failure is
  # logged and skipped; the next night retries the gap (spec §7).
  defp write_digest(thread, locale, kind, period_start, period_end, text) do
    messages = [%{role: "user", content: text, tool_calls: []}]

    with {:ok, %{text: content}} when is_binary(content) and content != "" <-
           provider().complete(messages, [], system: Prompts.digest(locale)),
         {:ok, _digest} <-
           %Digest{}
           |> Digest.changeset(%{
             thread_id: thread.id,
             kind: kind,
             period_start: period_start,
             period_end: period_end,
             content: content
           })
           |> Repo.insert() do
      :ok
    else
      other ->
        Logger.warning(
          "#{kind} digest #{period_start} for thread #{thread.id} not written: #{inspect(other)}"
        )
    end
  end

  defp provider, do: Application.fetch_env!(:ganesha, :assistant) |> Keyword.fetch!(:provider)
end
