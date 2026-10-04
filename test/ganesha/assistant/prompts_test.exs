defmodule Ganesha.Assistant.PromptsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Assistant.Prompts

  test "the teacher prompt carries the snapshot, and the summaries only when there are some" do
    with_summaries = Prompts.teacher("zh-TW", "SNAPSHOT-TEXT", "SUMMARY-TEXT")
    assert with_summaries =~ "SNAPSHOT-TEXT"
    assert with_summaries =~ "SUMMARY-TEXT"

    without = Prompts.teacher("zh-TW", "SNAPSHOT-TEXT", nil)
    assert without =~ "SNAPSHOT-TEXT"
    refute without =~ "SUMMARY-TEXT"

    # The summaries come with a heading of their own, and nil leaves it out too.
    added = String.split(with_summaries, "\n") -- String.split(without, "\n")
    assert "SUMMARY-TEXT" in added
    assert Enum.any?(added, &(&1 not in ["SUMMARY-TEXT", ""]))
  end

  test "each prompt follows the chat's language" do
    assert Prompts.teacher("en", "s", nil) != Prompts.teacher("zh-TW", "s", nil)
    assert Prompts.student("en") != Prompts.student("zh-TW")
    assert Prompts.digest("en") != Prompts.digest("zh-TW")
  end

  test "the teacher prompt never asks for cards and forbids markdown" do
    prompt = Prompts.teacher("zh-TW", "s", nil)
    refute prompt =~ "show_card"
    assert prompt =~ "markdown"
  end
end
