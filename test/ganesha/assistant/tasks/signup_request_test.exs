defmodule Ganesha.Assistant.Tasks.SignupRequestTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, People}
  alias Ganesha.Assistant.Tasks.SignupRequest
  alias Ganesha.Line.Client.Mock, as: LineMock

  defp ctx(line_user_id) do
    {:ok, thread} = Assistant.get_or_create_thread("user", line_user_id)
    %{thread: thread, locale: "zh-TW", today: ~D[2026-10-06]}
  end

  test "a linked student is named from the ledger, without asking LINE" do
    {:ok, student} = People.create_student(%{display_name: "Amy", line_user_id: "Uamy"})

    assert {:ok, %{student_id: student_id, parsed: parsed}} =
             SignupRequest.propose(%{"note" => " 想報名週一晚上 "}, ctx("Uamy"))

    assert student_id == student.id

    assert parsed == %{
             "note" => "想報名週一晚上",
             "student_id" => student.id,
             "student_name" => "Amy",
             "line_user_id" => "Uamy",
             "line_name" => nil,
             "new" => false
           }

    assert LineMock.lookups() == []
  end

  test "anyone else is a newcomer named by their LINE profile" do
    Process.put(:line_client_mock_profile, {:ok, %{"displayName" => "小美"}})

    assert {:ok, %{student_id: nil, parsed: parsed}} =
             SignupRequest.propose(%{"note" => "想報名"}, ctx("Unewcomer"))

    assert %{"new" => true, "line_user_id" => "Unewcomer", "line_name" => "小美"} = parsed
    assert LineMock.lookups() == [{:profile, "Unewcomer"}]
  end

  @tag :capture_log
  test "a failed profile lookup leaves the newcomer unnamed" do
    Process.put(:line_client_mock_profile, {:error, {404, %{}}})

    assert {:ok, %{parsed: %{"new" => true, "line_name" => nil}}} =
             SignupRequest.propose(%{"note" => "想報名"}, ctx("Unewcomer2"))
  end

  test "rejects a blank or missing note" do
    assert {:error, message} = SignupRequest.propose(%{"note" => "  "}, ctx("Ublank"))
    assert message =~ "needs a note"
    assert {:error, _} = SignupRequest.propose(%{}, ctx("Ublank"))
  end

  test "confirming only acknowledges it" do
    assert {:ok, {nil, nil}} = SignupRequest.apply(%{"note" => "想報名"}, "line:teacher")
  end

  test "the summary names the student, else the newcomer's LINE name, else neither" do
    student = %{"new" => false, "student_name" => "Amy", "note" => "週一晚上"}
    named = %{"new" => true, "line_name" => "小美", "note" => "週一晚上"}
    unnamed = %{"new" => true, "line_name" => nil, "note" => "週一晚上"}

    for locale <- ["zh-TW", "en"] do
      assert SignupRequest.summary(student, locale) =~ "Amy"
      assert SignupRequest.summary(named, locale) =~ "小美"
      assert SignupRequest.summary(unnamed, locale) =~ "週一晚上"
    end
  end
end
