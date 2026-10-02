defmodule Ganesha.Assistant.Tasks.SetLanguageTest do
  use Ganesha.DataCase

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Tasks.SetLanguage

  setup do
    {:ok, thread} = Assistant.get_or_create_thread("teacher", "Uteacher")
    {:ok, thread} = Assistant.set_locale(thread, "zh-TW")
    %{thread: thread, ctx: %{thread: thread, locale: "zh-TW", today: ~D[2026-10-02]}}
  end

  test "switches the chat's language at once and confirms in the new language", %{
    thread: thread,
    ctx: ctx
  } do
    assert {:ok, %{data: "Language switched to English."}} =
             SetLanguage.answer(%{"locale" => "en"}, ctx)

    assert Repo.reload!(thread).locale == "en"
  end

  test "rejects an unsupported locale and leaves the language alone", %{
    thread: thread,
    ctx: ctx
  } do
    assert {:error, message} = SetLanguage.answer(%{"locale" => "ja"}, ctx)
    assert message =~ "zh-TW or en"
    assert Repo.reload!(thread).locale == "zh-TW"
  end
end
