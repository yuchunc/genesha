defmodule Ganesha.Assistant.Tasks.AddSessionTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.AddSession
  alias GaneshaWeb.Fmt

  @input %{
    "date" => "2026-10-20",
    "start_time" => "19:00:00",
    "end_time" => "20:00:00",
    "label" => "期間限定",
    "style" => "流動"
  }

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  defp propose!(ctx, input \\ @input) do
    {:ok, %{parsed: parsed}} = AddSession.propose(input, ctx)
    parsed
  end

  defp october, do: Studio.sessions_in_month(~D[2026-10-01])

  describe "propose/2" do
    test "normalizes the input into ISO values, writing nothing", %{ctx: ctx} do
      input = %{@input | "start_time" => "19:00", "label" => " 期間限定 ", "style" => " 流動 "}

      assert {:ok, %{student_id: nil, parsed: parsed}} = AddSession.propose(input, ctx)

      assert parsed == %{
               "date" => "2026-10-20",
               "start_time" => "19:00:00",
               "end_time" => "20:00:00",
               "label" => "期間限定",
               "style" => "流動"
             }

      assert october() == []
    end

    test "returns a message for the model when a field is missing or malformed",
         %{ctx: ctx} do
      for input <- [
            Map.delete(@input, "date"),
            %{@input | "date" => "10/20"},
            %{@input | "start_time" => "7pm"},
            Map.delete(@input, "end_time"),
            %{@input | "label" => "  "},
            %{@input | "style" => 3},
            %{@input | "end_time" => "19:00:00"},
            %{@input | "end_time" => "18:00:00"}
          ] do
        assert {:error, message} = AddSession.propose(input, ctx)
        assert is_binary(message)
      end

      assert october() == []
    end

    test "rejects a standalone session already on that date, time and label", %{ctx: ctx} do
      {:ok, _} = AddSession.apply(propose!(ctx), "line:teacher")

      assert {:error, message} = AddSession.propose(@input, ctx)
      assert is_binary(message)
      assert length(october()) == 1
    end
  end

  describe "apply/2" do
    test "creates a scheduled standalone session with the proposed values", %{ctx: ctx} do
      parsed = propose!(ctx)

      assert {:ok, {"Ganesha.Studio.Session", session_id}} =
               AddSession.apply(parsed, "line:teacher")

      session = Studio.get_session!(session_id)
      assert session.slot_id == nil
      assert session.state == "scheduled"
      assert session.date == ~D[2026-10-20]
      assert session.start_time == ~T[19:00:00]
      assert session.end_time == ~T[20:00:00]
      assert session.label == "期間限定"
      assert session.style == "流動"
    end

    test "fails when the same session was added after propose", %{ctx: ctx} do
      parsed = propose!(ctx)
      {:ok, _} = AddSession.apply(parsed, "line:teacher")

      assert {:error, :duplicate_session} = AddSession.apply(parsed, "line:teacher")
      assert length(october()) == 1
    end
  end

  describe "describe/2" do
    test "shows the date, time and style of the new session", %{ctx: ctx} do
      parsed = propose!(ctx)
      date = ~D[2026-10-20]

      for locale <- ["zh-TW", "en"] do
        %{
          title: title,
          lines: [date_line, time_line, style_line],
          changes: changes,
          web_path: path
        } =
          AddSession.describe(parsed, locale)

        assert title =~ "期間限定"
        assert date_line =~ Format.session_day(date, locale)
        assert time_line =~ Fmt.time_range(~T[19:00:00], ~T[20:00:00])
        assert style_line =~ "流動"
        assert [{_label, nil, "期間限定"}] = changes
        assert path == "/class/2026/10"
      end
    end

    test "shows the stored values, not the current database", %{ctx: ctx} do
      parsed = %{propose!(ctx) | "date" => "2026-11-03", "label" => "週末班"}

      %{title: title, lines: [date_line | _], changes: [{_, nil, label}], web_path: path} =
        AddSession.describe(parsed, "zh-TW")

      assert title =~ "週末班"
      assert date_line =~ Format.session_day(~D[2026-11-03], "zh-TW")
      assert label == "週末班"
      assert path == "/class/2026/11"
    end
  end

  describe "summary/2" do
    test "summary names the date, time, label and style" do
      parsed = %{
        "date" => "2026-10-10",
        "start_time" => "10:00:00",
        "end_time" => "11:15:00",
        "label" => "週末班",
        "style" => "流動"
      }

      for locale <- ["zh-TW", "en"] do
        text = AddSession.summary(parsed, locale)
        for fact <- ["10/10", "10:00–11:15", "週末班", "流動"], do: assert(text =~ fact)
      end
    end
  end
end
