defmodule Ganesha.Assistant.MemoryTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.{Digest, Memory, Prompts}
  alias Ganesha.Assistant.Provider.Mock

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

  describe "write_missing_digests/2" do
    setup do
      Process.put(:digest_inputs, [])

      Mock.stub(fn [%{role: "user", content: content}], [], opts ->
        Process.put(:digest_inputs, Process.get(:digest_inputs) ++ [{opts[:system], content}])

        if content =~ "fail-day",
          do: {:error, :overloaded},
          else: {:ok, %{text: "summary", tool_calls: []}}
      end)

      :ok
    end

    test "writes a daily digest for each past day with counted messages and none yet", %{
      thread: thread
    } do
      put(thread, "user", "9/29 的事", ~U[2026-09-29 04:00:00Z])
      put(thread, "user", "9/30 的事", ~U[2026-09-30 04:00:00Z])
      put(thread, "assistant", "好的", ~U[2026-09-30 04:01:00Z])
      put(thread, "user", "今天的事", @this_morning)
      digest(thread, "daily", ~D[2026-09-29], ~D[2026-09-29], "already written")

      assert :ok = Memory.write_missing_digests(thread, @today)

      assert [{system, transcript}] = Process.get(:digest_inputs)
      assert system == Prompts.digest("zh-TW")
      assert transcript == "Teacher: 9/30 的事\nAssistant: 好的"

      assert [~D[2026-09-29], ~D[2026-09-30]] =
               Repo.all(
                 from d in Digest,
                   where: d.kind == "daily",
                   order_by: d.period_start,
                   select: d.period_start
               )
    end

    test "skips today and days more than 90 days ago", %{thread: thread} do
      put(thread, "user", "太久以前", ~U[2026-07-03 04:00:00Z])
      put(thread, "user", "今天", @this_morning)

      assert :ok = Memory.write_missing_digests(thread, @today)
      assert Process.get(:digest_inputs) == []
    end

    test "writes a weekly digest from each complete week's daily digests", %{thread: thread} do
      digest(thread, "daily", ~D[2026-09-21], ~D[2026-09-21], "週一的事")
      digest(thread, "daily", ~D[2026-09-27], ~D[2026-09-27], "週日的事")
      digest(thread, "daily", ~D[2026-09-28], ~D[2026-09-28], "這週還沒過完")

      assert :ok = Memory.write_missing_digests(thread, @today)

      assert [{_system, input}] = Process.get(:digest_inputs)
      assert input == "[2026-09-21]\n週一的事\n\n[2026-09-27]\n週日的事"

      assert [%Digest{period_start: ~D[2026-09-21], period_end: ~D[2026-09-27]}] =
               Repo.all(from d in Digest, where: d.kind == "weekly")
    end

    @tag :capture_log
    test "a day that fails is skipped and the others are written", %{thread: thread} do
      put(thread, "user", "fail-day", ~U[2026-09-29 04:00:00Z])
      put(thread, "user", "正常的一天", ~U[2026-09-30 04:00:00Z])

      assert :ok = Memory.write_missing_digests(thread, @today)
      assert [~D[2026-09-30]] = Repo.all(from d in Digest, select: d.period_start)
    end

    @tag :capture_log
    test "a week whose daily failed gets no weekly until the next run writes the daily", %{
      thread: thread
    } do
      put(thread, "user", "週一的事", ~U[2026-09-21 04:00:00Z])
      put(thread, "user", "fail-day", ~U[2026-09-27 04:00:00Z])

      assert :ok = Memory.write_missing_digests(thread, @today)
      refute Repo.exists?(from d in Digest, where: d.kind == "weekly")

      Mock.stub(fn _messages, [], _opts -> {:ok, %{text: "summary", tool_calls: []}} end)

      assert :ok = Memory.write_missing_digests(thread, @today)

      assert [{"daily", ~D[2026-09-21]}, {"daily", ~D[2026-09-27]}, {"weekly", ~D[2026-09-21]}] =
               Repo.all(
                 from d in Digest,
                   order_by: [d.kind, d.period_start],
                   select: {d.kind, d.period_start}
               )
    end

    @tag :capture_log
    test "a day whose message is unsent while its digest is written gets no digest", %{
      thread: thread
    } do
      put(thread, "user", "第一句", ~U[2026-09-30 04:00:00Z])
      unsent = put(thread, "user", "收回的話", ~U[2026-09-30 04:01:00Z])

      Mock.stub(fn _messages, [], _opts ->
        unsent |> Ecto.Changeset.change(content: nil) |> Repo.update!()
        {:ok, %{text: "summary", tool_calls: []}}
      end)

      assert :ok = Memory.write_missing_digests(thread, @today)
      refute Repo.exists?(from(d in Digest))
    end

    @tag :capture_log
    test "a week whose daily is invalidated while its weekly is written gets no weekly", %{
      thread: thread
    } do
      digest(thread, "daily", ~D[2026-09-21], ~D[2026-09-21], "週一的事")
      digest(thread, "daily", ~D[2026-09-24], ~D[2026-09-24], "週四的事")

      Mock.stub(fn _messages, [], _opts ->
        Memory.invalidate_digests(thread.id, ~D[2026-09-24])
        {:ok, %{text: "summary", tool_calls: []}}
      end)

      assert :ok = Memory.write_missing_digests(thread, @today)
      refute Repo.exists?(from d in Digest, where: d.kind == "weekly")
    end
  end

  describe "invalidate_digests/2" do
    test "drops that day's daily digest and the weekly digest containing it", %{thread: thread} do
      digest(thread, "daily", ~D[2026-09-24], ~D[2026-09-24], "that day")
      digest(thread, "daily", ~D[2026-09-25], ~D[2026-09-25], "next day")
      digest(thread, "weekly", ~D[2026-09-21], ~D[2026-09-27], "that week")
      digest(thread, "weekly", ~D[2026-09-14], ~D[2026-09-20], "the week before")

      assert :ok = Memory.invalidate_digests(thread.id, ~D[2026-09-24])

      assert Repo.all(
               from d in Digest,
                 order_by: [d.kind, d.period_start],
                 select: {d.kind, d.period_start}
             ) == [{"daily", ~D[2026-09-25]}, {"weekly", ~D[2026-09-14]}]
    end
  end
end
