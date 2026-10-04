defmodule Ganesha.Assistant.Tasks.CancelSessionTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.CancelSession
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

    {:ok, package} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, student} = People.create_student(%{display_name: "蘭子"})

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: package.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, _} = Roster.enroll(session, student, purchase)

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      session: Studio.get_session!(session.id),
      student: student,
      purchase: purchase
    }
  end

  defp propose!(c, reason \\ "颱風假") do
    {:ok, %{parsed: parsed}} =
      CancelSession.propose(%{"session_id" => c.session.id, "reason" => reason}, c.ctx)

    parsed
  end

  defp credits(student), do: Roster.available_credits(student.id, ~D[2026-12-01])

  describe "propose/2" do
    test "captures the trimmed reason and how many credits the card will issue, writing nothing",
         c do
      assert {:ok, %{student_id: nil, parsed: parsed}} =
               CancelSession.propose(
                 %{"session_id" => c.session.id, "reason" => " 颱風假 "},
                 c.ctx
               )

      assert parsed["session_id"] == c.session.id
      assert parsed["reason"] == "颱風假"
      assert parsed["credit_count"] == 1
      assert parsed["session_date"] == "2026-10-07"
      assert Studio.get_session!(c.session.id).state == "scheduled"
      assert credits(c.student) == []
    end

    test "returns a message for the model when the reason is missing or blank", c do
      for input <- [
            %{"session_id" => c.session.id},
            %{"session_id" => c.session.id, "reason" => ""},
            %{"session_id" => c.session.id, "reason" => "   "},
            %{"session_id" => c.session.id, "reason" => 3}
          ] do
        assert {:error, message} = CancelSession.propose(input, c.ctx)
        assert is_binary(message)
      end

      assert Studio.get_session!(c.session.id).state == "scheduled"
    end

    test "rejects an already cancelled session", c do
      {:ok, _} = Studio.cancel_session(c.session, "already")

      assert {:error, message} =
               CancelSession.propose(%{"session_id" => c.session.id, "reason" => "颱風假"}, c.ctx)

      assert is_binary(message)
    end

    test "rejects an unknown or missing session id", c do
      assert {:error, unknown} =
               CancelSession.propose(%{"session_id" => -1, "reason" => "颱風假"}, c.ctx)

      assert {:error, missing} = CancelSession.propose(%{"reason" => "颱風假"}, c.ctx)
      assert is_binary(unknown) and is_binary(missing)
    end
  end

  describe "apply/2" do
    test "cancels the session and issues each seated student a credit carrying the reason", c do
      parsed = propose!(c)

      assert {:ok, {"Ganesha.Studio.Session", session_id}} =
               CancelSession.apply(parsed, "line:teacher")

      assert session_id == c.session.id
      cancelled = Studio.get_session!(c.session.id)
      assert cancelled.state == "cancelled"
      assert cancelled.cancel_reason == "颱風假"
      assert [credit] = credits(c.student)
      assert credit.origin_session_id == c.session.id
      assert credit.note == "颱風假"
    end

    test "fails if the session was cancelled after the Draft was made", c do
      parsed = propose!(c)
      {:ok, _} = Studio.cancel_session(c.session, "already")

      assert {:error, :session_not_scheduled} = CancelSession.apply(parsed, "line:teacher")
      assert credits(c.student) == []
      assert Studio.get_session!(c.session.id).cancel_reason == "already"
    end

    test "fails if the roster changed after the Draft was made", c do
      parsed = propose!(c)
      {:ok, student2} = People.create_student(%{display_name: "丹丹"})
      {:ok, _} = Roster.enroll(c.session, student2, c.purchase)

      assert {:error, :roster_changed} = CancelSession.apply(parsed, "line:teacher")
      assert Studio.get_session!(c.session.id).state == "scheduled"
      assert credits(c.student) == []
      assert credits(student2) == []
    end

    test "fails if the session no longer exists", c do
      parsed = propose!(c)

      assert {:error, :not_found} =
               CancelSession.apply(%{parsed | "session_id" => -1}, "line:teacher")
    end
  end

  describe "describe/2" do
    test "shows the session, the reason and the credit count", c do
      parsed = propose!(c)
      date = ~D[2026-10-07]

      for locale <- ["zh-TW", "en"] do
        %{title: title, lines: [session_line, reason_line], changes: changes, web_path: path} =
          CancelSession.describe(parsed, locale)

        assert title =~ Fmt.short_date(date)
        assert title =~ "基礎"
        assert session_line =~ Format.session_day(date, locale)
        assert session_line =~ Fmt.session_time_range(c.session)
        assert reason_line =~ "颱風假"
        assert [{_state, scheduled, cancelled}, {_credits, nil, issued}] = changes
        assert scheduled != cancelled
        assert issued =~ "1"
        assert path == "/sessions/#{c.session.id}"
      end
    end

    test "shows the stored values, not the current database", c do
      parsed = propose!(c, "老師生病")
      {:ok, _} = Studio.cancel_session(c.session, "already")

      %{lines: [_session, reason_line], changes: [_state, {_credits, nil, issued}]} =
        CancelSession.describe(%{parsed | "credit_count" => 7}, "zh-TW")

      assert reason_line =~ "老師生病"
      assert issued =~ "7"
    end
  end

  describe "summary/2" do
    test "summary names the session, the reason and the credits issued" do
      parsed = %{
        "session_date" => "2026-10-08",
        "session_time" => "19:00–20:15",
        "session_label" => "基礎",
        "reason" => "颱風假",
        "credit_count" => 3
      }

      for locale <- ["zh-TW", "en"] do
        text = CancelSession.summary(parsed, locale)
        for fact <- ["10/8", "19:00–20:15", "基礎", "颱風假", "3"], do: assert(text =~ fact)
      end

      refute CancelSession.summary(%{parsed | "credit_count" => 0}, "zh-TW") =~ "補課券"
    end
  end
end
