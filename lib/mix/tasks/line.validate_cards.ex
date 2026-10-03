defmodule Mix.Tasks.Line.ValidateCards do
  @shortdoc "Validate every LINE card shape against the Messaging API (spec §8)"

  @moduledoc """
  Builds one of every card type from in-memory sample data (`Ganesha.Line.Cards.samples/1`)
  and POSTs each to LINE's `/v2/bot/message/validate/reply` with the configured
  channel token. Nothing is sent to users. Prints PASS or FAIL per sample and
  exits non-zero when any card fails.

      set -a && source .env.dev && set +a && mix line.validate_cards
  """

  use Mix.Task

  alias Ganesha.Line.{Cards, Client}

  @locales ["zh-TW", "en"]

  @impl true
  def run(_args) do
    # The Draft card's web button needs the Endpoint's URL, so the app must run.
    # Oban stays idle: this task must never process queued webhook events.
    Mix.Task.run("app.config")
    oban = Application.fetch_env!(:ganesha, Oban)
    Application.put_env(:ganesha, Oban, Keyword.merge(oban, queues: false, plugins: false))
    Mix.Task.run("app.start")

    failed =
      Enum.flat_map(@locales, &locale_checks/1)
      |> Kernel.++([{"choices-only reply", [choices_message()]}])
      |> Enum.reject(fn {label, messages} -> validate(label, messages) == :ok end)
      |> length()

    if failed == 0 do
      Mix.shell().info("All cards passed validation.")
    else
      Mix.raise("#{failed} card(s) failed LINE validation")
    end
  end

  # Samples list each lookup card filled, then again with nothing to list.
  defp locale_checks(locale) do
    locale
    |> Cards.samples()
    |> Enum.map_reduce(MapSet.new(), fn {type, _} = card, seen ->
      label = if type in seen, do: "#{locale} #{type} (empty)", else: "#{locale} #{type}"
      {check(card, label, locale), MapSet.put(seen, type)}
    end)
    |> elem(0)
  end

  defp check({:draft, draft} = card, _label, locale) do
    alt = Cards.history_line(card, locale)

    {"#{locale} draft carousel",
     [Client.flex_message(alt, Cards.draft_carousel([draft], locale))]}
  end

  defp check(card, label, locale) do
    {label, [Client.flex_message(Cards.history_line(card, locale), Cards.render(card, locale))]}
  end

  defp choices_message do
    Client.text_message("x")
    |> Map.put(:quickReply, %{
      items: [
        %{type: "action", action: %{type: "message", label: "A", text: "A"}},
        %{type: "action", action: %{type: "message", label: "B", text: "B"}}
      ]
    })
  end

  defp validate(label, messages) do
    case Client.validate_reply(messages) do
      :ok ->
        Mix.shell().info("PASS  #{label}")
        :ok

      {:error, reason} ->
        Mix.shell().error("FAIL  #{label}: #{inspect(reason)}")
        :error
    end
  end
end
