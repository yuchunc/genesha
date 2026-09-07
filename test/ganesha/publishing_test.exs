defmodule Ganesha.PublishingTest do
  use Ganesha.DataCase
  alias Ganesha.{Catalog, People, Publishing, Roster, Sales, Studio}

  defp august_monday do
    {:ok, _} =
      Catalog.create_package(%{
        name: "月課程",
        kind: "monthly",
        price_per_class: 400,
        included_makeups: 1
      })

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

  test "schedule_block/1 shows the label, time, dates and package price" do
    august_monday()

    text = Publishing.schedule_block(~D[2026-08-01])

    assert text =~ "8月開課時間表"
    assert text =~ "早晨練習｜週一 基礎瑜伽"
    assert text =~ "9:30－10:45"
    assert text =~ "8/3"
    assert text =~ "8/31"
    # Five Mondays at 400 per class.
    assert text =~ "2000元 /5 堂"
  end

  test "schedule_block/1 marks a session whose style differs from the slot default" do
    {_slot, sessions} = august_monday()
    {:ok, _} = Studio.set_style(Enum.at(sessions, 3), "流動")

    text = Publishing.schedule_block(~D[2026-08-01])

    assert text =~ "*流動8/24", "an overridden style is marked as in her own document"
  end

  test "schedule_block/1 omits cancelled dates" do
    {_slot, sessions} = august_monday()
    {:ok, _} = Studio.cancel_session(hd(sessions), "颱風假")

    text = Publishing.schedule_block(~D[2026-08-01])

    refute text =~ "8/3、"
    assert text =~ "1600元 /4 堂", "the price follows the remaining dates"
  end

  test "signup_block/1 renders numbered places and an 其他 section per slot" do
    august_monday()

    text = Publishing.signup_block(~D[2026-08-01])

    assert text =~ "請寫下姓名"
    assert text =~ "早晨練習｜週一 基礎瑜伽"
    assert text =~ "1."
    assert text =~ "6."
    assert text =~ "其他："
  end

  test "roster_block/1 lists attendees per date and annotates non-enrolled kinds" do
    {slot, sessions} = august_monday()
    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    monthly = hd(Catalog.list_active_packages())

    {:ok, monthly_purchase} =
      Sales.create_purchase(%{
        student_id: lulu.id,
        package_id: monthly.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, drop_pkg} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, drop_purchase} =
      Sales.create_purchase(%{
        student_id: jennifer.id,
        package_id: drop_pkg.id,
        list_price: 450
      })

    session = hd(sessions)
    {:ok, _} = Roster.enroll(session, lulu, monthly_purchase)
    {:ok, _} = Roster.add_drop_in(session, jennifer, drop_purchase)

    text = Publishing.roster_block(~D[2026-08-01])

    assert text =~ "8/3"
    assert text =~ "Lulu"
    assert text =~ "（單）Jennifer"
  end

  test "roster_block/1 marks a no-show" do
    {slot, sessions} = august_monday()
    {:ok, student} = People.create_student(%{display_name: "素容"})
    monthly = hd(Catalog.list_active_packages())

    {:ok, purchase} =
      Sales.create_purchase(%{
        student_id: student.id,
        package_id: monthly.id,
        slot_id: slot.id,
        list_price: 2000
      })

    {:ok, attendance} = Roster.enroll(hd(sessions), student, purchase)
    {:ok, _} = Roster.mark_no_show(attendance)

    assert Publishing.roster_block(~D[2026-08-01]) =~ "素容（未到）"
  end

  test "roster_block/1 omits a cancelled session, matching schedule_block/1" do
    {_slot, sessions} = august_monday()
    {:ok, _} = Studio.cancel_session(hd(sessions), "颱風假")

    text = Publishing.roster_block(~D[2026-08-01])

    refute text =~ "8/3：", "a cancelled date must not appear in either block"
    assert text =~ "8/10"
  end

  test "roster_block/1 keeps the kind marker on a no-show drop-in" do
    {_slot, sessions} = august_monday()
    {:ok, jennifer} = People.create_student(%{display_name: "Jennifer"})

    {:ok, drop_pkg} =
      Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 450})

    {:ok, drop_purchase} =
      Sales.create_purchase(%{student_id: jennifer.id, package_id: drop_pkg.id, list_price: 450})

    {:ok, attendance} = Roster.add_drop_in(hd(sessions), jennifer, drop_purchase)
    {:ok, _} = Roster.mark_no_show(attendance)

    assert Publishing.roster_block(~D[2026-08-01]) =~ "（單）Jennifer（未到）"
  end

  test "announcement/1 renders only the settings fields that are present" do
    august_monday()

    {:ok, _} = Publishing.update_settings(%{account_number: "111001756051"})

    text = Publishing.announcement(~D[2026-08-01])

    refute text =~ "銀行代號", "no bank_code means no bank-name line"
    assert text =~ "帳號： 111001756051"
  end

  test "announcement/1 includes the bank footer from settings" do
    august_monday()

    {:ok, _} =
      Publishing.update_settings(%{
        bank_name: "連線商業銀行",
        bank_code: "824",
        account_number: "111001756051",
        transfer_deadline: "8/15",
        closing_note: "＊＊或者 line pay Money"
      })

    text = Publishing.announcement(~D[2026-08-01])

    assert text =~ "8月開課時間表"
    assert text =~ "請寫下姓名"
    assert text =~ "麻煩於8/15前轉帳，並告知帳後五碼。"
    assert text =~ "824"
    assert text =~ "111001756051"
    assert text =~ "＊＊或者 line pay Money"
  end

  test "announcement/1 omits footer lines that have no settings yet" do
    august_monday()

    text = Publishing.announcement(~D[2026-08-01])

    refute text =~ "麻煩於"
    refute text =~ "銀行代號"
  end
end
