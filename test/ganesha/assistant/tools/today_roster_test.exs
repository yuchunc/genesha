defmodule Ganesha.Assistant.Tools.TodayRosterTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.TodayRoster
  alias Ganesha.{Catalog, Clock, People, Roster, Sales, Studio}

  test "lists today's sessions with their roster" do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: Date.day_of_week(Clock.today()),
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        default_style: "Hatha",
        label: "今日班"
      })

    {:ok, session} =
      Studio.create_session(%{slot_id: slot.id, date: Clock.today(), style: "Hatha"})

    {:ok, student} = People.create_student(%{display_name: "Lulu"})
    {:ok, pkg} = Catalog.create_package(%{name: "單堂", kind: "drop_in", price_per_class: 400})

    {:ok, purchase} =
      Sales.create_purchase(%{student_id: student.id, package_id: pkg.id, list_price: 400})

    {:ok, _} = Roster.add_drop_in(session, student, purchase)

    {content, draft_id} = TodayRoster.call(%{}, nil)
    assert draft_id == nil
    assert [%{"roster" => [%{"student" => "Lulu"}]}] = Jason.decode!(content)
  end
end
