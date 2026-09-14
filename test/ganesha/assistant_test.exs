defmodule Ganesha.AssistantTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant
  alias Ganesha.{Catalog, People, Roster, Sales, Studio}

  test "get_or_create_thread/2 creates once and reuses on repeat calls" do
    assert {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert {:ok, same} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert thread.id == same.id
  end

  test "get_or_create_thread/2 keeps group and teacher threads separate per source_id" do
    assert {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
    assert {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Cabc")
    refute group.id == teacher.id
  end

  test "get_or_create_thread/2 rejects an unknown source_type" do
    assert {:error, changeset} = Assistant.get_or_create_thread("student", "U1")
    assert "is invalid" in errors_on(changeset).source_type
  end

  test "append_message/4 and list_messages/1 round-trip in insertion order" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    {:ok, _} = Assistant.append_message(thread, "user", "誰欠錢？", nil)

    {:ok, _} =
      Assistant.append_message(thread, "assistant", nil, [
        %{id: "t1", name: "student_balance", input: %{}}
      ])

    assert [first, second] = Assistant.list_messages(thread)
    assert first.role == "user"
    assert first.content == "誰欠錢？"
    assert second.role == "assistant"
    assert [%{"id" => "t1", "name" => "student_balance"}] = second.tool_calls
  end

  test "append_message/4 rejects an unknown role" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    assert {:error, changeset} = Assistant.append_message(thread, "system", "x", nil)
    assert "is invalid" in errors_on(changeset).role
  end

  test "create_draft/2 stamps the thread's latest user message as its origin" do
    {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
    {:ok, _} = Assistant.append_message(thread, "user", "2.Lulu （Line pay 1200元）", nil)

    assert {:ok, draft} =
             Assistant.create_draft(thread, %{
               kind: "payment",
               parsed: %{"amount" => 1200, "method" => "line_pay"},
               confidence: 0.8
             })

    [origin] = Assistant.list_messages(thread)
    assert draft.origin_message_id == origin.id
    assert draft.state == "pending"
  end

  test "create_draft/2 rejects an unknown kind" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

    assert {:error, changeset} =
             Assistant.create_draft(thread, %{kind: "bogus", parsed: %{}})

    assert "is invalid" in errors_on(changeset).kind
  end

  test "get_draft!/1 fetches by id" do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})
    assert Assistant.get_draft!(draft.id).id == draft.id
  end

  describe "apply_draft/2 and discard_draft/1" do
    test "applying a payment draft records and confirms a payment" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "payment",
          parsed: %{
            "purchase_id" => purchase.id,
            "amount" => 400,
            "method" => "cash",
            "paid_on" => Date.to_iso8601(Ganesha.Clock.today())
          }
        })

      assert {:ok, updated} = Assistant.apply_draft(draft, "line:teacher")
      assert updated.state == "applied"
      assert updated.applied_record_type == "Ganesha.Sales.Payment"

      [payment] = Sales.list_payments_for_purchase(purchase.id)
      assert payment.state == "confirmed"
      assert payment.source == "line_draft"
    end

    test "applying a payment draft with no paid_on defaults to today" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

      {:ok, purchase} =
        Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "payment",
          parsed: %{"purchase_id" => purchase.id, "amount" => 400, "method" => "cash"}
        })

      assert {:ok, _updated} = Assistant.apply_draft(draft, "line:teacher")

      [payment] = Sales.list_payments_for_purchase(purchase.id)
      assert payment.paid_on == Ganesha.Clock.today()
    end

    test "applying a payment draft without a purchase_id fails instead of guessing" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "payment", parsed: %{"amount" => 400}})

      assert {:error, :missing_purchase_id} = Assistant.apply_draft(draft, "line:teacher")
      assert Assistant.get_draft!(draft.id).state == "pending"
    end

    test "applying an attendance draft creates an attendance row" do
      {:ok, slot} =
        Studio.create_slot(%{
          weekday: 1,
          start_time: ~T[09:00:00],
          end_time: ~T[10:00:00],
          default_style: "Hatha",
          label: "一"
        })

      {:ok, session} =
        Studio.create_session(%{slot_id: slot.id, date: ~D[2026-09-14], style: "Hatha"})

      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "attendance",
          parsed: %{"session_id" => session.id, "student_id" => student.id, "kind" => "drop_in"}
        })

      assert {:ok, updated} = Assistant.apply_draft(draft, "line:teacher")
      assert updated.applied_record_type == "Ganesha.Roster.Attendance"
      assert [attendance] = Roster.list_for_session(session)
      assert attendance.student_id == student.id
    end

    test "applying an attendance draft proposing a makeup is refused, never books one for free" do
      {:ok, student} = People.create_student(%{display_name: "Lulu"})
      {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")

      {:ok, draft} =
        Assistant.create_draft(thread, %{
          kind: "attendance",
          parsed: %{"session_id" => 1, "student_id" => student.id, "kind" => "makeup"}
        })

      assert {:error, :makeup_requires_credit} = Assistant.apply_draft(draft, "line:teacher")
      assert Assistant.get_draft!(draft.id).state == "pending"
      assert Roster.list_for_student(student.id) == []
    end

    test "applying a makeup_request draft marks it applied without creating a ledger row" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")

      {:ok, draft} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "8/17"}})

      assert {:ok, updated} = Assistant.apply_draft(draft, "line:teacher")
      assert updated.state == "applied"
      assert is_nil(updated.applied_record_type)
    end

    test "applying or discarding an already-resolved draft fails cleanly" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, draft} = Assistant.create_draft(thread, %{kind: "unknown", parsed: %{}})
      {:ok, discarded} = Assistant.discard_draft(draft)

      assert {:error, :not_pending} = Assistant.discard_draft(discarded)
      assert {:error, :not_pending} = Assistant.apply_draft(discarded, "line:teacher")
    end
  end
end
