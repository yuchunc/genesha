defmodule Ganesha.Assistant.Tools.UpcomingSessionsTest do
  use Ganesha.DataCase
  alias Ganesha.Assistant.Tools.UpcomingSessions
  alias Ganesha.{Clock, Studio}

  test "lists sessions in the next N days" do
    {:ok, slot} =
      Studio.create_slot(%{
        weekday: Date.day_of_week(Date.add(Clock.today(), 2)),
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        default_style: "Hatha",
        label: "近日班"
      })

    {:ok, _} = Studio.create_session(%{slot_id: slot.id, date: Date.add(Clock.today(), 2), style: "Hatha"})

    {content, draft_id} = UpcomingSessions.call(%{"days" => 7}, nil)
    assert draft_id == nil
    assert [%{"style" => "Hatha"}] = Jason.decode!(content)
  end

  test "defaults to 7 days when no days argument is given" do
    {content, nil} = UpcomingSessions.call(%{}, nil)
    assert Jason.decode!(content) == []
  end
end
