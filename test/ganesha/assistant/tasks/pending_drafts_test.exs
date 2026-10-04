defmodule Ganesha.Assistant.Tasks.PendingDraftsTest do
  use Ganesha.DataCase

  alias Ganesha.{Assistant, Clock}
  alias Ganesha.Assistant.Tasks.PendingDrafts
  alias Ganesha.Line.Cards

  setup do
    {:ok, teacher} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, group} = Assistant.get_or_create_thread("group", "Cgroup")

    %{
      teacher: teacher,
      group: group,
      ctx: %{thread: teacher, locale: "zh-TW", today: Clock.today()}
    }
  end

  defp makeup_draft(thread, note) do
    {:ok, draft} =
      Assistant.create_draft(thread, %{kind: "makeup_request", parsed: %{"note" => note}})

    draft
  end

  test "names every pending Draft from every chat, oldest first", c do
    from_teacher = makeup_draft(c.teacher, "8/17")
    from_group = makeup_draft(c.group, "8/24")
    {:ok, _} = c.teacher |> makeup_draft("8/31") |> Assistant.discard_draft()

    assert {:ok, %{data: data, draft_ids: ids}} = PendingDrafts.answer(%{}, c.ctx)
    assert ids == [from_teacher.id, from_group.id]

    for draft <- [from_teacher, from_group] do
      assert data =~ Cards.history_line({:draft, draft}, "zh-TW")
    end
  end

  test "with nothing pending, names no Drafts", c do
    assert {:ok, %{draft_ids: []}} = PendingDrafts.answer(%{}, c.ctx)
  end
end
