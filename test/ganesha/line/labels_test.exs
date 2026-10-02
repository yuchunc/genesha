defmodule Ganesha.Line.LabelsTest do
  use ExUnit.Case, async: true

  alias Ganesha.Line.Labels

  @keys ~w(confirm discard open_web more_drafts choose draft pending options confirmed discarded
           failed already_handled replaced not_found exception tag_confirmed tag_discarded
           tag_failed tag_already_handled tag_replaced tag_exception apology unknown_action
           welcome)a

  test "every label speaks both languages, and they differ" do
    for key <- @keys do
      zh = Labels.t(key, "zh-TW")
      en = Labels.t(key, "en")

      assert is_binary(zh) and zh != "", "#{key} has no zh-TW label"
      assert is_binary(en) and en != "", "#{key} has no en label"
      assert zh != en, "#{key} is not translated"
    end
  end

  test "any locale other than en gets Traditional Chinese" do
    for key <- @keys, locale <- [nil, "ja", "zh-TW"] do
      assert Labels.t(key, locale) == Labels.t(key, "zh-TW")
    end
  end

  test "fills in an outcome's details" do
    for locale <- ["zh-TW", "en"] do
      text = Labels.t(:failed, locale, title: "收款 Amy NT$3,200", reason: "missing_purchase_id")

      assert text =~ "收款 Amy NT$3,200"
      assert text =~ "missing_purchase_id"
      refute text =~ "%{"
    end

    assert Labels.t(:more_drafts, "en", count: 3) =~ "3"
  end
end
