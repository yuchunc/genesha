defmodule Ganesha.Assistant.Tasks.BookOneOffTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Enrolling, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.BookOneOff

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, student} = People.create_student(%{display_name: "Lulu"})

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

    {:ok, drop_in} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})
    {:ok, trial} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 300})

    {:ok, monthly} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 350})

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      student: student,
      session: session,
      drop_in: drop_in,
      trial: trial,
      monthly: monthly
    }
  end

  defp input(student, session, package) do
    %{"student_id" => student.id, "session_id" => session.id, "package_id" => package.id}
  end

  describe "propose/2" do
    test "resolves the ids and captures the roster before the booking", c do
      assert {:ok, %{student_id: student_id, parsed: parsed}} =
               BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)

      assert student_id == c.student.id
      assert parsed["before_count"] == 0
      assert parsed["price"] == 400
      assert parsed["session_date"] == "2026-10-07"
      assert parsed["session_label"] == "基礎"
      assert parsed["session_time"] == "19:00–20:15"
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "rejects a monthly package", c do
      assert {:error, message} = BookOneOff.propose(input(c.student, c.session, c.monthly), c.ctx)
      assert message =~ "drop_in or trial"
    end

    test "rejects a cancelled session", c do
      {:ok, _} = Studio.cancel_session(c.session, "颱風")
      assert {:error, message} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      assert message =~ "cancelled"
    end

    test "rejects a student who is already in the session", c do
      {:ok, _} = Enrolling.add_one_off(c.session, c.student, c.drop_in, [])
      assert {:error, message} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      assert message =~ "already booked"
    end

    test "rejects an unknown session", c do
      bad = %{"student_id" => c.student.id, "session_id" => -1, "package_id" => c.drop_in.id}
      assert {:error, message} = BookOneOff.propose(bad, c.ctx)
      assert message =~ "no session with id -1"
    end
  end

  describe "apply/2" do
    test "creates the purchase and seats the student", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)

      assert {:ok, {"Ganesha.Sales.Purchase", purchase_id}} =
               BookOneOff.apply(parsed, "line:teacher")

      assert [%{student_id: student_id, kind: "drop_in", purchase_id: ^purchase_id}] =
               Roster.list_for_session(c.session)

      assert student_id == c.student.id
      assert Sales.get_purchase!(purchase_id).list_price == 400
    end

    test "a trial package seats a trial", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.trial), c.ctx)
      assert {:ok, _} = BookOneOff.apply(parsed, "line:teacher")
      assert [%{kind: "trial"}] = Roster.list_for_session(c.session)
    end

    test "fails if the session was cancelled after the Draft was made", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      {:ok, _} = Studio.cancel_session(c.session, "颱風")

      assert {:error, :session_cancelled} = BookOneOff.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
    end

    test "fails if the package was closed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      {:ok, _} = Catalog.update_package(c.drop_in, %{active: false})

      assert {:error, :package_unavailable} = BookOneOff.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
      assert Roster.list_for_session(c.session) == []
    end

    test "fails if the package price changed after the Draft was made", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      {:ok, _} = Catalog.update_package(c.drop_in, %{price_per_class: 450})

      assert {:error, :price_changed} = BookOneOff.apply(parsed, "line:teacher")
      assert Sales.list_purchases_for_student(c.student.id) == []
      assert Roster.list_for_session(c.session) == []
    end

    test "a custom amount of 0 is what the card shows and what the purchase owes", c do
      input = Map.put(input(c.student, c.session, c.drop_in), "custom_amount", 0)
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input, c.ctx)

      assert {_label, nil, owed} = List.last(BookOneOff.describe(parsed, "zh-TW").changes)
      assert owed == Format.money(0)

      assert {:ok, {"Ganesha.Sales.Purchase", purchase_id}} =
               BookOneOff.apply(parsed, "line:teacher")

      purchase = Sales.get_purchase!(purchase_id)
      assert purchase.custom_amount == 0
      assert purchase.list_price == 400
    end

    test "returns the changeset when the student was booked in the meantime", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)
      {:ok, _} = Enrolling.add_one_off(c.session, c.student, c.drop_in, [])

      assert {:error, %Ecto.Changeset{}} = BookOneOff.apply(parsed, "line:teacher")
      assert length(Sales.list_purchases_for_student(c.student.id)) == 1
    end
  end

  describe "describe/2" do
    test "shows the session and the roster before → after", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.drop_in), c.ctx)

      assert %{
               title: "單堂 Lulu 10/7",
               lines: ["課堂：10/7 週三 基礎 19:00–20:15", "方案：單堂 NT$400"],
               changes: [{"名單", "0 人", "1 人"}, {"應付", nil, "NT$400"}],
               web_path: web_path
             } = BookOneOff.describe(parsed, "zh-TW")

      assert web_path == "/sessions/#{c.session.id}"
    end

    test "speaks English when the chat does", c do
      {:ok, %{parsed: parsed}} = BookOneOff.propose(input(c.student, c.session, c.trial), c.ctx)

      assert %{
               title: "Trial Lulu 10/7",
               lines: ["Session: Wed 10/7 基礎 19:00–20:15", "Package: 體驗 NT$300"],
               changes: [{"Roster", "0", "1"}, {"Owed", nil, "NT$300"}]
             } = BookOneOff.describe(parsed, "en")
    end
  end
end
