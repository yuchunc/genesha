defmodule Ganesha.Assistant.Tasks.StudentSummaryTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Catalog, People, Roster, Sales, Studio}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.StudentSummary
  alias Ganesha.Roster.Credit

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

    {:ok, lulu} = People.create_student(%{display_name: "Lulu"})

    {:ok, package} =
      Catalog.create_package(%{name: "月課程", kind: "monthly", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: lulu.id, package_id: package.id, list_price: 1600})

    # Booked in date order, so the newest attendance row is the latest date.
    [september, oct7, oct14, oct21] =
      for date <- [~D[2026-09-30], ~D[2026-10-07], ~D[2026-10-14], ~D[2026-10-21]] do
        {:ok, session} = Studio.create_session(%{slot_id: slot.id, date: date, style: "Hatha"})
        {:ok, _} = Roster.enroll(session, lulu, purchase)
        session
      end

    {:ok, _} = Studio.cancel_session(oct21, "颱風")

    {:ok, confirmed} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 400,
        method: "cash",
        paid_on: ~D[2026-10-01]
      })

    {:ok, _} = Sales.confirm_payment(confirmed, "teacher")

    {:ok, _claimed} =
      Sales.record_payment(%{
        purchase_id: purchase.id,
        amount: 300,
        method: "line_pay",
        paid_on: ~D[2026-10-02]
      })

    credit = fn attrs ->
      {:ok, _} =
        %Credit{}
        |> Credit.changeset(Map.put(attrs, :student_id, lulu.id))
        |> Repo.insert()
    end

    credit.(%{source: "cancellation", origin_session_id: september.id, expires_on: nil})

    credit.(%{
      source: "package",
      origin_purchase_id: purchase.id,
      seq: 1,
      expires_on: ~D[2026-09-30]
    })

    %{
      ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]},
      lulu: lulu,
      september: september,
      oct7: oct7,
      oct14: oct14,
      oct21: oct21
    }
  end

  test "sums what she owes, her purchases, upcoming sessions and open credits", c do
    assert {:ok, %{data: data} = answer} =
             StudentSummary.answer(%{"student_id" => c.lulu.id}, c.ctx)

    refute Map.has_key?(answer, :card)

    assert String.starts_with?(
             data,
             "Lulu (student #{c.lulu.id}): owes #{Format.money(1200)}, 1 open credit(s)"
           )

    assert data =~
             "1 purchase(s): 月課程 paid #{Format.money(400)} of #{Format.money(1600)}"

    assert data =~
             ~r/Session #{c.oct7.id} #{Regex.escape(Format.session_day(~D[2026-10-07], "zh-TW"))} 基礎/

    assert data =~
             ~r/Session #{c.oct14.id} #{Regex.escape(Format.session_day(~D[2026-10-14], "zh-TW"))} 基礎/

    refute data =~ ~r/Session #{c.september.id}\b/
    refute data =~ ~r/Session #{c.oct21.id}\b/
  end

  test "answers a student with nothing on file", c do
    {:ok, amy} = People.create_student(%{display_name: "Amy"})

    assert {:ok, %{data: data}} = StudentSummary.answer(%{"student_id" => amy.id}, c.ctx)

    assert data ==
             "Amy (student #{amy.id}): owes #{Format.money(0)}, 0 open credit(s); 0 purchase(s)"
  end

  test "rejects an unknown, non-integer or missing student_id", c do
    assert {:error, _} = StudentSummary.answer(%{"student_id" => c.lulu.id + 1000}, c.ctx)
    assert {:error, _} = StudentSummary.answer(%{"student_id" => "#{c.lulu.id}"}, c.ctx)
    assert {:error, _} = StudentSummary.answer(%{}, c.ctx)
  end
end
