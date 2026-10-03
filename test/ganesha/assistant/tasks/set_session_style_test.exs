defmodule Ganesha.Assistant.Tasks.SetSessionStyleTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.SetSessionStyle
  alias GaneshaWeb.Fmt

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 3,
        start_time: ~T[19:00:00],
        end_time: ~T[20:15:00],
        default_style: "Hatha",
        label: "基礎"
      })

    {:ok, session} =
      Studio.create_session(%{slot_id: slot.id, date: ~D[2026-10-07], style: "Hatha"})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      session: Studio.get_session!(session.id)
    }
  end

  defp propose!(c, style \\ "流動") do
    {:ok, %{parsed: parsed}} =
      SetSessionStyle.propose(%{"session_id" => c.session.id, "style" => style}, c.ctx)

    parsed
  end

  describe "propose/2" do
    test "captures the trimmed new style and the current one, writing nothing", c do
      assert {:ok, %{student_id: nil, parsed: parsed}} =
               SetSessionStyle.propose(
                 %{"session_id" => c.session.id, "style" => " 流動 "},
                 c.ctx
               )

      assert parsed["session_id"] == c.session.id
      assert parsed["style"] == "流動"
      assert parsed["before_style"] == "Hatha"
      assert parsed["session_date"] == "2026-10-07"
      assert Studio.get_session!(c.session.id).style == "Hatha"
    end

    test "returns a message for the model when the style is missing or blank", c do
      for input <- [
            %{"session_id" => c.session.id},
            %{"session_id" => c.session.id, "style" => ""},
            %{"session_id" => c.session.id, "style" => "   "},
            %{"session_id" => c.session.id, "style" => 3}
          ] do
        assert {:error, message} = SetSessionStyle.propose(input, c.ctx)
        assert is_binary(message)
      end
    end

    test "rejects a cancelled session", c do
      {:ok, _} = Studio.cancel_session(c.session, "颱風假")

      assert {:error, message} =
               SetSessionStyle.propose(%{"session_id" => c.session.id, "style" => "流動"}, c.ctx)

      assert is_binary(message)
    end

    test "rejects an unknown or missing session id", c do
      assert {:error, unknown} =
               SetSessionStyle.propose(%{"session_id" => -1, "style" => "流動"}, c.ctx)

      assert {:error, missing} = SetSessionStyle.propose(%{"style" => "流動"}, c.ctx)
      assert is_binary(unknown) and is_binary(missing)
    end
  end

  describe "apply/2" do
    test "sets the new style on that session", c do
      parsed = propose!(c)

      assert {:ok, {"Ganesha.Studio.Session", id}} =
               SetSessionStyle.apply(parsed, "line:teacher")

      assert id == c.session.id
      assert Studio.get_session!(c.session.id).style == "流動"
    end

    test "fails when the style changed after propose", c do
      parsed = propose!(c)
      {:ok, _} = Studio.set_style(c.session, "其他")

      assert {:error, :style_changed} = SetSessionStyle.apply(parsed, "line:teacher")
      assert Studio.get_session!(c.session.id).style == "其他"
    end

    test "fails when the session was cancelled after propose", c do
      parsed = propose!(c)
      {:ok, _} = Studio.cancel_session(c.session, "颱風假")

      assert {:error, :session_cancelled} = SetSessionStyle.apply(parsed, "line:teacher")
      assert Studio.get_session!(c.session.id).style == "Hatha"
    end

    test "fails when the session no longer exists", c do
      parsed = propose!(c)

      assert {:error, :not_found} =
               SetSessionStyle.apply(%{parsed | "session_id" => -1}, "line:teacher")
    end
  end

  describe "describe/2" do
    test "shows the session and the style before and after", c do
      parsed = propose!(c)
      date = ~D[2026-10-07]

      for locale <- ["zh-TW", "en"] do
        %{title: title, lines: [session_line], changes: changes, web_path: path} =
          SetSessionStyle.describe(parsed, locale)

        assert title =~ Fmt.short_date(date)
        assert title =~ "基礎"
        assert session_line =~ Format.session_day(date, locale)
        assert session_line =~ Fmt.session_time_range(c.session)
        assert [{_label, "Hatha", "流動"}] = changes
        assert path == "/sessions/#{c.session.id}"
      end
    end

    test "shows the stored values, not the current database", c do
      parsed = propose!(c)
      {:ok, _} = Studio.set_style(c.session, "其他")

      %{changes: [{_label, before, after_value}]} =
        SetSessionStyle.describe(%{parsed | "style" => "陰瑜珈"}, "zh-TW")

      assert {before, after_value} == {"Hatha", "陰瑜珈"}
    end
  end
end
