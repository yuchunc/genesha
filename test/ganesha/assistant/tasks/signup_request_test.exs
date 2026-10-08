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

  describe "in the Group chat" do
    # The group thread's source_id is the group; the asker is the sender of
    # the message being handled, as stored by ProcessEventWorker.
    defp group_ctx(sender_id, sender_name) do
      {:ok, thread} = Assistant.get_or_create_thread("group", "Cgroupsignup")

      {:ok, _} =
        Assistant.append_message(thread, "user", "我想報名週一早上的課", nil,
          sender_id: sender_id,
          sender_name: sender_name
        )

      %{thread: thread, locale: "zh-TW", today: ~D[2026-10-07]}
    end

    test "an unlinked sender is named by the stored group display name, without asking LINE" do
      assert {:ok, %{student_id: nil, parsed: parsed}} =
               SignupRequest.propose(%{"note" => "想報名週一早上"}, group_ctx("Ugroupnew", "小美"))

      assert %{"new" => true, "line_user_id" => "Ugroupnew", "line_name" => "小美"} = parsed
      assert LineMock.lookups() == []
    end

    test "a linked sender is that student" do
      {:ok, amy} = People.create_student(%{display_name: "Amy", line_user_id: "Ugroupamy"})

      assert {:ok, %{student_id: student_id, parsed: %{"new" => false, "student_name" => "Amy"}}} =
               SignupRequest.propose(%{"note" => "想報名"}, group_ctx("Ugroupamy", "Amy L"))

      assert student_id == amy.id
    end

    test "a message without a sender proposes nothing" do
      assert {:error, _reason} =
               SignupRequest.propose(%{"note" => "想報名"}, group_ctx(nil, nil))
    end
  end

  test "rejects a blank or missing note" do
    assert {:error, message} = SignupRequest.propose(%{"note" => "  "}, ctx("Ublank"))
    assert message =~ "needs a note"
    assert {:error, _} = SignupRequest.propose(%{}, ctx("Ublank"))
  end

  test "rejects a note longer than 300 characters after trim" do
    long = String.duplicate("課", 301)

    assert {:error, message} = SignupRequest.propose(%{"note" => long}, ctx("Ulong"))
    assert message =~ "300"
    assert message =~ "shorten"
  end

  test "the teacher message quotes the student's words as theirs" do
    student = %{
      "new" => false,
      "student_id" => 3,
      "student_name" => "Amy",
      "note" => "想報名週一晚上"
    }

    assert SignupRequest.teacher_message(1, student, "zh-TW") =~ "學生原話：「想報名週一晚上」"
    assert SignupRequest.teacher_message(1, student, "en") =~ ~s|Their words: "想報名週一晚上"|

    unlinked = %{
      "new" => true,
      "line_user_id" => "Ux",
      "line_name" => "小美",
      "note" => "想報名"
    }

    zh = SignupRequest.teacher_message(2, unlinked, "zh-TW")
    assert zh =~ "學生原話：「想報名」"
    refute zh =~ "想報名：想報名"
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

  test "an unlinked asker's card says their LINE ID is unlinked, not that they are new" do
    named = %{"new" => true, "line_name" => "小美", "note" => "週一晚上"}
    unnamed = %{"new" => true, "line_name" => nil, "note" => "週一晚上"}

    assert SignupRequest.summary(named, "zh-TW") == "未連結的 LINE 用戶（LINE：小美）想報名：週一晚上"
    assert SignupRequest.summary(unnamed, "zh-TW") == "未連結的 LINE 用戶想報名：週一晚上"

    assert SignupRequest.summary(named, "en") ==
             "Unlinked LINE user (LINE: 小美) wants to sign up: 週一晚上"

    assert SignupRequest.summary(unnamed, "en") == "An unlinked LINE user wants to sign up: 週一晚上"
  end

  test "an unlinked asker's request message says the LINE ID isn't linked to any student" do
    parsed = %{
      "new" => true,
      "line_user_id" => "Unewcomer",
      "line_name" => "小美",
      "note" => "想報名週一晚上"
    }

    zh = SignupRequest.teacher_message(7, parsed, "zh-TW")
    assert zh =~ "這個 LINE ID 還沒連結任何學生"
    assert zh =~ "Unewcomer"
    refute zh =~ "還不是學生"

    en = SignupRequest.teacher_message(7, parsed, "en")
    assert en =~ "LINE ID isn't linked to a student"
    assert en =~ "Unewcomer"
    refute en =~ "not a student"
  end

  test "the request message asks for one enroll carrying the request's id" do
    linked = %{"new" => false, "student_id" => 3, "student_name" => "Amy", "note" => "想報名"}

    unlinked = %{
      "new" => true,
      "line_user_id" => "Unewcomer",
      "line_name" => "小美",
      "note" => "想報名"
    }

    for locale <- ["zh-TW", "en"] do
      known = SignupRequest.teacher_message(7, linked, locale)
      assert known =~ "enroll"
      assert known =~ "signup_request_id 7"
      assert known =~ "student_id 3"

      newcomer = SignupRequest.teacher_message(7, unlinked, locale)
      assert newcomer =~ "signup_request_id 7"
      assert newcomer =~ "student_id"
      assert newcomer =~ "new_student_name"
      assert newcomer =~ "小美"
      assert newcomer =~ "ask_teacher"
      refute newcomer =~ "add_student"
      refute newcomer =~ "繼續"
    end
  end
end
