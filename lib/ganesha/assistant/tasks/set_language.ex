defmodule Ganesha.Assistant.Tasks.SetLanguage do
  @moduledoc """
  Control tool `set_language` (spec §3.2, §6.5): switches the chat's language
  at once. Not a ledger change, so no Draft (spec §2 rule 1).
  """
  @behaviour Ganesha.Assistant.Task

  alias Ganesha.Assistant

  @impl true
  def name, do: "set_language"

  @impl true
  def kind, do: :control

  @impl true
  def tool do
    %{
      description: """
      Switch this chat's reply language when the person asks for it. zh-TW is \
      Traditional Chinese, en is English.\
      """,
      input_schema: %{
        type: "object",
        properties: %{locale: %{type: "string", enum: ["zh-TW", "en"]}},
        required: ["locale"]
      }
    }
  end

  @impl true
  def answer(%{"locale" => locale}, %{thread: thread}) do
    case Assistant.set_locale(thread, locale) do
      {:ok, _thread} -> {:ok, %{data: confirmation(locale)}}
      {:error, _reason} -> {:error, "unsupported locale #{inspect(locale)}; use zh-TW or en"}
    end
  end

  def answer(_input, _ctx), do: {:error, "set_language needs a locale: zh-TW or en"}

  defp confirmation("en"), do: "Language switched to English."
  defp confirmation(_locale), do: "已切換為繁體中文。"
end
