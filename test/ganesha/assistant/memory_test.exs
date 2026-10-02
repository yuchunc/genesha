defmodule Ganesha.Assistant.MemoryTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Digest, Memory}

  # 12:00 in Asia/Taipei on 2026-10-02.
  @now ~U[2026-10-02 04:00:00Z]
  @today ~D[2026-10-02]
  @yesterday ~U[2026-10-01 04:00:00Z]
  @this_morning ~U[2026-10-02 01:00:00Z]

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{thread: thread}
  end

  defp put(thread, role, content, at, tool_calls \\ nil) do
    {:ok, message} = Assistant.append_message(thread, role, content, tool_calls)
    message |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
  end

  # `n` exchanges one minute apart after `start`: user "u<i>", optionally a
  # tool round, then the assistant's final "a<i>".
  defp exchanges(thread, n, start, opts \\ []) do
    for i <- 1..n do
      at = DateTime.add(start, i * 60)
      put(thread, "user", "u#{i}", at)

      if opts[:tools] do
        put(thread, "assistant", nil, at, [%{id: "t#{i}", name: "echo", input: %{}}])
        put(thread, "tool", nil, at, [%{tool_use_id: "t#{i}", content: "ok"}])
      end

      put(thread, "assistant", "a#{i}", at)
    end
  end

  defp counted(messages) do
    Enum.filter(
      messages,
      &(&1.role == "user" or (&1.role == "assistant" and &1.tool_calls in [nil, []]))
    )
  end

  defp digest(thread, kind, from, to, content) do
    Repo.insert!(%Digest{
      thread_id: thread.id,
      kind: kind,
      period_start: from,
      period_end: to,
      content: content
    })
  end

  describe "history/3" do
    test "keeps the last 30 counted messages and every message after the oldest of them", %{
      thread: thread
    } do
      exchanges(thread, 20, @yesterday, tools: true)

      history = Memory.history(thread, :teacher, @now)

      assert length(counted(history)) == 30
      assert %{role: "user", content: "u6"} = hd(history)
      assert length(history) == 60
    end

    test "always starts at a user message", %{thread: thread} do
      exchanges(thread, 16, @yesterday)
      put(thread, "assistant", "[已確認] 草稿 #1 收款 Lulu NT$400", DateTime.add(@yesterday, 3600))

      history = Memory.history(thread, :teacher, @now)

      assert %{role: "user", content: "u3"} = hd(history)
      assert length(counted(history)) == 29
    end

    test "counts an assistant message with empty tool calls", %{thread: thread} do
      exchanges(thread, 15, @yesterday)
      put(thread, "assistant", "a16", DateTime.add(@yesterday, 3600), [])

      history = Memory.history(thread, :teacher, @now)

      assert %{role: "user", content: "u2"} = hd(history)
      assert length(counted(history)) == 29
    end

    test "takes all of today's messages when there are more than 30", %{thread: thread} do
      exchanges(thread, 10, @yesterday)
      exchanges(thread, 20, @this_morning)

      history = Memory.history(thread, :teacher, @now)

      assert length(counted(history)) == 40
      assert %{content: "u1", inserted_at: ~U[2026-10-02 01:01:00Z]} = hd(history)
    end

    test "caps today's messages at 100 counted", %{thread: thread} do
      exchanges(thread, 60, ~U[2026-10-02 00:00:00Z])

      history = Memory.history(thread, :teacher, @now)

      assert length(counted(history)) == 100
      assert %{role: "user", content: "u11"} = hd(history)
    end

    test "a Student chat keeps only the last 30 counted messages" do
      {:ok, student_chat} = Assistant.get_or_create_thread("user", "Ustudent")
      exchanges(student_chat, 20, @this_morning)

      assert length(counted(Memory.history(student_chat, :student, @now))) == 30
    end

    test "an empty thread has no history", %{thread: thread} do
      assert Memory.history(thread, :teacher, @now) == []
    end
  end

  describe "summaries/2" do
    test "is nil when there are no digests", %{thread: thread} do
      assert Memory.summaries(thread, @today) == nil
    end

    test "weeks that ended at least 15 days ago, then the days after the newest week", %{
      thread: thread
    } do
      put(thread, "user", "今天的訊息", @this_morning)
      digest(thread, "weekly", ~D[2026-06-15], ~D[2026-06-21], "too old")
      digest(thread, "weekly", ~D[2026-09-07], ~D[2026-09-13], "week A")
      digest(thread, "weekly", ~D[2026-09-21], ~D[2026-09-27], "too recent")
      digest(thread, "daily", ~D[2026-09-10], ~D[2026-09-10], "inside week A")
      digest(thread, "daily", ~D[2026-09-14], ~D[2026-09-14], "day 14")
      digest(thread, "daily", ~D[2026-09-30], ~D[2026-09-30], "day 30")

      assert Memory.summaries(thread, @today) ==
               "[2026-09-07 – 2026-09-13]\nweek A\n\n[2026-09-14]\nday 14\n\n[2026-09-30]\nday 30"
    end

    test "without weeks: days from the last 14 days, up to the oldest message in the window", %{
      thread: thread
    } do
      put(thread, "user", "那天的訊息", ~U[2026-09-28 04:00:00Z])
      digest(thread, "daily", ~D[2026-09-17], ~D[2026-09-17], "15 days ago")
      digest(thread, "daily", ~D[2026-09-18], ~D[2026-09-18], "14 days ago")
      digest(thread, "daily", ~D[2026-09-28], ~D[2026-09-28], "window day")
      digest(thread, "daily", ~D[2026-09-29], ~D[2026-09-29], "inside the window")

      assert Memory.summaries(thread, @today) ==
               "[2026-09-18]\n14 days ago\n\n[2026-09-28]\nwindow day"
    end
  end
end
