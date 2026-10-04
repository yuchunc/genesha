defmodule Ganesha.AssistantTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, Clock, Enrolling, People, Sales, Studio}
  alias Ganesha.Assistant.Draft
  alias Ganesha.Assistant.Tasks.{BookOneOff, RecordPayment}
  alias Ganesha.Sales.Payment

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{thread: thread}
  end

  defp ctx(thread), do: %{thread: thread, locale: "zh-TW", today: Clock.today()}

  defp makeup(thread, note, student_id \\ nil) do
    Assistant.create_draft(thread, %{
      kind: "makeup_request",
      student_id: student_id,
      parsed: %{"note" => note}
    })
  end

  defp payment_draft(thread, overrides \\ %{}) do
    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, package} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, _} =
      Sales.create_purchase(%{student_id: student.id, package_id: package.id, list_price: 400})

    {:ok, %{student_id: student_id, parsed: parsed}} =
      RecordPayment.propose(
        %{"student_id" => student.id, "amount" => 400, "method" => "cash"},
        ctx(thread)
      )

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "record_payment",
        student_id: student_id,
        parsed: Map.merge(parsed, overrides)
      })

    draft
  end

  defp one_off_draft(thread, overrides \\ %{}) do
    {:ok, student} = People.create_student(%{display_name: "Amy"})

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

    {:ok, package} = Catalog.create_package(%{name: "體驗", kind: "trial", price_per_class: 300})

    {:ok, %{student_id: student_id, parsed: parsed}} =
      BookOneOff.propose(
        %{"student_id" => student.id, "session_id" => session.id, "package_id" => package.id},
        ctx(thread)
      )

    {:ok, draft} =
      Assistant.create_draft(thread, %{
        kind: "book_one_off",
        student_id: student_id,
        parsed: Map.merge(parsed, overrides)
      })

    %{draft: draft, student: student, session: session, package: package}
  end

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

  test "append_message/4 and list_messages/1 round-trip in insertion order", %{thread: thread} do
    {:ok, _} = Assistant.append_message(thread, "user", "誰欠錢？", nil)

    {:ok, _} =
      Assistant.append_message(thread, "assistant", nil, [
        %{id: "t1", name: "record_payment", input: %{}}
      ])

    assert [first, second] = Assistant.list_messages(thread)
    assert first.role == "user"
    assert first.content == "誰欠錢？"
    assert second.role == "assistant"
    assert [%{"id" => "t1", "name" => "record_payment"}] = second.tool_calls
  end

  test "append_message/4 rejects an unknown role", %{thread: thread} do
    assert {:error, changeset} = Assistant.append_message(thread, "system", "x", nil)
    assert "is invalid" in errors_on(changeset).role
  end

  test "get_draft!/1 fetches by id", %{thread: thread} do
    {:ok, draft} = makeup(thread, "8/17")
    assert Assistant.get_draft!(draft.id).id == draft.id
  end

  describe "create_draft/3" do
    test "stamps the thread's latest user message as its origin" do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, _} = Assistant.append_message(thread, "user", "蘭子補課8/17or 8/31", nil)

      assert {:ok, draft} = makeup(thread, "8/17 或 8/31")

      [origin] = Assistant.list_messages(thread)
      assert draft.origin_message_id == origin.id
      assert draft.state == "pending"
    end

    test "rejects a kind that names no change task, including retired kinds", %{thread: thread} do
      for kind <- ["bogus", "payment", "attendance", "unknown", "ask_teacher"] do
        assert {:error, changeset} = Assistant.create_draft(thread, %{kind: kind, parsed: %{}})
        assert "is invalid" in errors_on(changeset).kind
      end
    end

    test "replaces a pending Draft of the same thread", %{thread: thread} do
      {:ok, old} = makeup(thread, "8/17")

      assert {:ok, new} =
               Assistant.create_draft(
                 thread,
                 %{kind: "makeup_request", parsed: %{"note" => "8/24"}},
                 replaces: old.id
               )

      old = Repo.reload!(old)
      assert old.state == "replaced"
      assert old.replaced_by_id == new.id
      assert new.state == "pending"
    end

    test "leaves another thread's Draft and a settled Draft alone", %{thread: thread} do
      {:ok, group} = Assistant.get_or_create_thread("group", "Cabc")
      {:ok, foreign} = makeup(group, "x")
      {:ok, settled} = makeup(thread, "y")
      {:ok, _} = Assistant.discard_draft(settled)

      for old <- [foreign, settled] do
        assert {:ok, _} =
                 Assistant.create_draft(
                   thread,
                   %{kind: "makeup_request", parsed: %{"note" => "z"}},
                   replaces: old.id
                 )
      end

      assert Repo.reload!(foreign).state == "pending"
      assert Repo.reload!(settled).state == "discarded"
    end
  end

  describe "confirm_draft/2" do
    test "applies a record_payment Draft through Sales", %{thread: thread} do
      draft = payment_draft(thread)

      assert {:ok,
              %Draft{state: "applied", applied_record_type: "Ganesha.Sales.Payment"} = applied} =
               Assistant.confirm_draft(draft, "line:teacher")

      payment = Repo.get!(Payment, applied.applied_record_id)
      assert payment.state == "confirmed"
      assert payment.confirmed_by == "line:teacher"
    end

    test "applies exactly once when confirmed twice at the same time", %{thread: thread} do
      draft = payment_draft(thread)

      results =
        [
          Task.async(fn -> Assistant.confirm_draft(draft, "line:teacher") end),
          Task.async(fn -> Assistant.confirm_draft(draft, "line:teacher") end)
        ]
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, %Draft{state: "applied"}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :not_pending})) == 1
      assert Repo.aggregate(Payment, :count) == 1
    end

    test "marks the Draft failed with an atom reason and writes nothing", %{thread: thread} do
      draft = payment_draft(thread, %{"purchase_id" => nil})

      assert {:error, {:failed, %Draft{state: "failed", failure_reason: "missing_purchase_id"}}} =
               Assistant.confirm_draft(draft, "line:teacher")

      assert Repo.reload!(draft).state == "failed"
      assert Repo.aggregate(Payment, :count) == 0
    end

    test "marks the Draft failed with the changeset's errors and rolls back the whole change", %{
      thread: thread
    } do
      %{draft: draft, student: student, session: session, package: package} =
        one_off_draft(thread)

      # Booked on the web after the Draft was made.
      {:ok, _} = Enrolling.add_one_off(session, student, package, [])

      assert {:error, {:failed, failed}} = Assistant.confirm_draft(draft, "line:teacher")
      assert failed.failure_reason == "session_id: has already been taken"
      assert length(Sales.list_purchases_for_student(student.id)) == 1
    end

    test "an exception rolls back and leaves the Draft pending", %{thread: thread} do
      %{draft: draft, student: student} = one_off_draft(thread, %{"custom_amount" => -5})

      assert_raise MatchError, fn -> Assistant.confirm_draft(draft, "line:teacher") end

      assert Repo.reload!(draft).state == "pending"
      assert Sales.list_purchases_for_student(student.id) == []
    end

    test "a Draft that is not pending is never applied", %{thread: thread} do
      {:ok, discarded} = makeup(thread, "a")
      {:ok, _} = Assistant.discard_draft(discarded)
      {:ok, replaced} = makeup(thread, "b")

      {:ok, _} =
        Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => "c"}},
          replaces: replaced.id
        )

      assert {:error, :not_pending} = Assistant.confirm_draft(discarded, "line:teacher")
      assert {:error, :not_pending} = Assistant.confirm_draft(replaced, "line:teacher")
    end

    test "a makeup_request is acknowledged without a ledger row", %{thread: thread} do
      {:ok, draft} = makeup(thread, "8/17")

      assert {:ok, %Draft{state: "applied", applied_record_type: nil, applied_record_id: nil}} =
               Assistant.confirm_draft(draft, "line:teacher")
    end
  end

  describe "discard_draft/1" do
    test "discards a pending Draft", %{thread: thread} do
      {:ok, draft} = makeup(thread, "8/17")
      assert {:ok, %Draft{state: "discarded"}} = Assistant.discard_draft(draft)
    end

    test "refuses a Draft that was already settled, even from a stale copy", %{thread: thread} do
      {:ok, draft} = makeup(thread, "8/17")
      {:ok, _} = Assistant.confirm_draft(draft, "line:teacher")

      assert {:error, :not_pending} = Assistant.discard_draft(draft)
      assert Repo.reload!(draft).state == "applied"
    end
  end

  test "list_pending_drafts/0 lists pending Drafts oldest first with the student loaded", %{
    thread: thread
  } do
    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})
    {:ok, first} = makeup(thread, "a", lulu.id)
    {:ok, middle} = makeup(thread, "b")
    {:ok, last} = makeup(thread, "c")
    {:ok, _} = Assistant.discard_draft(middle)

    assert [%Draft{id: first_id, student: %{display_name: "Lulu"}}, %Draft{id: last_id}] =
             Assistant.list_pending_drafts()

    assert {first_id, last_id} == {first.id, last.id}
  end

  describe "draft_summary/2" do
    test "is the Draft's task summary", %{thread: thread} do
      draft = payment_draft(thread)
      assert Assistant.draft_summary(draft, "zh-TW") =~ "Lulu"
      assert Assistant.draft_summary(draft, "zh-TW") =~ "NT$400"
    end

    test "falls back to the kind for a retired Draft" do
      assert Assistant.draft_summary(%Draft{kind: "attendance", parsed: %{}}, "zh-TW") ==
               "attendance"
    end
  end
end
