defmodule Ganesha.Assistant.Tasks.OpenCreditsTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.Format
  alias Ganesha.Assistant.Tasks.OpenCredits
  alias Ganesha.Roster.Credit

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    %{ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  defp credit(name, source, expires_on) do
    {:ok, student} = People.create_student(%{display_name: name})

    {:ok, _} =
      %Credit{}
      |> Credit.changeset(%{student_id: student.id, source: source, expires_on: expires_on})
      |> Repo.insert()

    student
  end

  defp day(date), do: Format.session_day(date, "zh-TW")

  test "lists unspent credits soonest expiry first and counts this month's expiring", c do
    amy = credit("Amy", "cancellation", nil)
    bob = credit("Bob", "package", ~D[2026-11-30])
    lulu = credit("Lulu", "package", ~D[2026-10-31])
    dan = credit("Dan", "package", ~D[2026-10-02])
    cat = credit("Cat", "package", ~D[2026-10-01])

    assert {:ok, %{data: data, card: {:credits, payload}}} = OpenCredits.answer(%{}, c.ctx)

    assert payload == %{
             "count" => 4,
             "expiring_count" => 2,
             "rows" => [
               %{"student" => "Dan", "source" => "package", "expires" => day(~D[2026-10-02])},
               %{"student" => "Lulu", "source" => "package", "expires" => day(~D[2026-10-31])},
               %{"student" => "Bob", "source" => "package", "expires" => day(~D[2026-11-30])},
               %{"student" => "Amy", "source" => "cancellation", "expires" => nil}
             ]
           }

    for student <- [amy, bob, lulu, dan] do
      assert data =~ ~r/student #{student.id}\b/
    end

    refute data =~ ~r/student #{cat.id}\b/
  end

  test "answers a studio with no open credits", c do
    credit("Cat", "package", ~D[2026-09-30])

    assert {:ok, %{data: data, card: {:credits, payload}}} = OpenCredits.answer(%{}, c.ctx)

    assert payload == %{"count" => 0, "expiring_count" => 0, "rows" => []}
    refute data =~ "student"
  end
end
