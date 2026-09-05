defmodule Ganesha.Roster.CreditTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Repo, Roster, Sales, Studio}

  defp monday_slot_with_sessions do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 1,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週一 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {slot, sessions}
  end

  defp friday_slot_with_sessions do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: 5,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "早晨練習｜週五 基礎瑜伽"
      })

    {:ok, sessions} = Studio.generate_month(slot, ~D[2026-08-01])
    {slot, sessions}
  end

  defp enrolled_monthly(slot, sessions, name) do
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "月課程-#{System.unique_integer([:positive])}",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 1600
      })

    for session <- sessions, do: {:ok, _} = Roster.enroll(session, student, purchase)
    %{student: student, purchase: purchase}
  end

  test "mint_package_credits/1 expires the credit at the Taipei month end" do
    {slot, sessions} = monday_slot_with_sessions()
    %{purchase: purchase, student: student} = enrolled_monthly(slot, sessions, "Lulu")

    assert {:ok, [credit]} = Roster.mint_package_credits(purchase)
    assert credit.source == "package"
    assert credit.student_id == student.id
    # Earliest attended session is 2026-08-03, so expiry is the end of August.
    assert credit.expires_on == ~D[2026-08-31]
  end

  test "mint_package_credits/1 is idempotent" do
    {slot, sessions} = monday_slot_with_sessions()
    %{purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")

    {:ok, first} = Roster.mint_package_credits(purchase)
    {:ok, second} = Roster.mint_package_credits(purchase)

    assert length(first) == 1
    assert length(second) == 1
    assert hd(first).id == hd(second).id
  end

  test "mint_package_credits/1 grants nothing until the purchase has attendance" do
    {slot, _sessions} = monday_slot_with_sessions()
    {:ok, student} = People.create_student(%{display_name: "Nobody"})

    {:ok, pkg} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: pkg.id,
        slot_id: slot.id,
        list_price: 1600
      })

    assert {:ok, []} = Roster.mint_package_credits(purchase),
           "a purchase has no month until it has attendance rows"
  end

  test "a drop-in package grants no credit" do
    {_slot, sessions} = monday_slot_with_sessions()
    {:ok, student} = People.create_student(%{display_name: "Jennifer"})

    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 450})

    {:ok, _} = Roster.add_drop_in(hd(sessions), student, purchase)

    assert {:ok, []} = Roster.mint_package_credits(purchase)
  end

  test "issue_cancellation_credits/1 grants one never-expiring credit per enrolled student" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: lanzi} = enrolled_monthly(slot, sessions, "蘭子")
    %{student: dandan} = enrolled_monthly(slot, sessions, "丹丹")

    {:ok, cancelled} = Studio.cancel_session(hd(sessions), "颱風假")

    assert {:ok, credits} = Roster.issue_cancellation_credits(cancelled)
    assert length(credits) == 2
    assert Enum.all?(credits, &(&1.source == "cancellation"))
    assert Enum.all?(credits, &is_nil(&1.expires_on))
    assert Enum.all?(credits, &(&1.note == "颱風假"))
    assert Enum.sort(Enum.map(credits, & &1.student_id)) == Enum.sort([lanzi.id, dandan.id])
  end

  test "issue_cancellation_credits/1 is idempotent" do
    {slot, sessions} = monday_slot_with_sessions()
    _ = enrolled_monthly(slot, sessions, "蘭子")
    {:ok, cancelled} = Studio.cancel_session(hd(sessions), "颱風假")

    {:ok, first} = Roster.issue_cancellation_credits(cancelled)
    {:ok, second} = Roster.issue_cancellation_credits(cancelled)

    assert length(first) == 1
    assert hd(first).id == hd(second).id
  end

  test "book_makeup/3 spends a credit on another weekday and creates a free row" do
    {monday, monday_sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(monday, monday_sessions, "蘭子")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)

    {_friday, friday_sessions} = friday_slot_with_sessions()
    target = hd(friday_sessions)

    assert {:ok, attendance} = Roster.book_makeup(target, student, credit)
    assert attendance.kind == "makeup"
    assert is_nil(attendance.purchase_id), "a makeup has no sale behind it"
    assert attendance.credit_id == credit.id

    assert Roster.available_credits(student.id, target.date) == [],
           "the credit must be spent, not merely referenced"
  end

  test "book_makeup/3 refuses a credit belonging to another student" do
    {slot, sessions} = monday_slot_with_sessions()
    %{purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)
    {:ok, stranger} = People.create_student(%{display_name: "Stranger"})

    assert {:error, :credit_not_owned} =
             Roster.book_makeup(Enum.at(sessions, 1), stranger, credit)
  end

  test "book_makeup/3 refuses an already spent credit" do
    {monday, monday_sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(monday, monday_sessions, "Lulu")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)

    {_friday, friday_sessions} = friday_slot_with_sessions()
    {:ok, _} = Roster.book_makeup(Enum.at(friday_sessions, 0), student, credit)

    reloaded = Repo.reload!(credit)

    assert {:error, :credit_already_consumed} =
             Roster.book_makeup(Enum.at(friday_sessions, 1), student, reloaded)
  end

  test "book_makeup/3 refuses a credit that expired before the session date" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")
    {:ok, [credit]} = Roster.mint_package_credits(purchase)

    {:ok, tuesday} =
      Studio.create_slot(%{
        weekday: 2,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "週二"
      })

    {:ok, september} = Studio.generate_month(tuesday, ~D[2026-09-01])

    assert {:error, :credit_expired} = Roster.book_makeup(hd(september), student, credit)
  end

  test "a cancellation credit still works in a later month" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: student} = enrolled_monthly(slot, sessions, "蘭子")
    {:ok, cancelled} = Studio.cancel_session(hd(sessions), "颱風假")
    {:ok, [credit]} = Roster.issue_cancellation_credits(cancelled)

    {:ok, tuesday} =
      Studio.create_slot(%{
        weekday: 2,
        start_time: ~T[09:30:00],
        end_time: ~T[10:45:00],
        default_style: "基礎",
        label: "週二"
      })

    {:ok, september} = Studio.generate_month(tuesday, ~D[2026-09-01])

    assert {:ok, attendance} = Roster.book_makeup(hd(september), student, credit)
    assert attendance.kind == "makeup"
  end

  test "available_credits/2 excludes expired and spent credits" do
    {slot, sessions} = monday_slot_with_sessions()
    %{student: student, purchase: purchase} = enrolled_monthly(slot, sessions, "Lulu")
    {:ok, _} = Roster.mint_package_credits(purchase)

    assert length(Roster.available_credits(student.id, ~D[2026-08-20])) == 1
    assert Roster.available_credits(student.id, ~D[2026-09-01]) == []
  end
end
