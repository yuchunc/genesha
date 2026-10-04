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

    assert {:ok, %{data: data} = answer} = OpenCredits.answer(%{}, c.ctx)

    refute Map.has_key?(answer, :card)

    assert data ==
             "4 open credit(s), 2 expiring this month: " <>
               Enum.join(
                 [
                   "Dan (student #{dan.id}) package, expires #{day(~D[2026-10-02])}",
                   "Lulu (student #{lulu.id}) package, expires #{day(~D[2026-10-31])}",
                   "Bob (student #{bob.id}) package, expires #{day(~D[2026-11-30])}",
                   "Amy (student #{amy.id}) cancellation, no expiry"
                 ],
                 "; "
               )

    refute data =~ ~r/student #{cat.id}\b/
  end

  test "answers a studio with no open credits", c do
    credit("Cat", "package", ~D[2026-09-30])

    assert {:ok, %{data: "0 open credit(s)"}} = OpenCredits.answer(%{}, c.ctx)
  end
end
