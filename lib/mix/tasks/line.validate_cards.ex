defmodule Mix.Tasks.Line.ValidateCards do
  @shortdoc "Validate the LINE Draft card and choice chips against the Messaging API"

  @moduledoc """
  Validates the Draft card and choice chips against the Messaging API: builds a
  Draft carousel per locale from an unsaved sample Draft and POSTs each to
  LINE's `/v2/bot/message/validate/reply` with the configured channel token.
  Nothing is sent to users. Prints PASS or FAIL per check and exits non-zero
  when any fails.

      mix line.validate_cards   # credentials come from .env.dev via mise.toml
  """

  use Mix.Task

  alias Ganesha.Assistant
  alias Ganesha.Assistant.Draft
  alias Ganesha.Line.{Cards, Client}

  @locales ["zh-TW", "en"]

  @impl true
  def run(_args) do
    # The LINE client's HTTP pool (Req) starts with the app, so the app must run.
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

  defp locale_checks(locale) do
    makeup = %Draft{
      id: 1,
      kind: "makeup_request",
      parsed: %{"student_name" => "Amy", "note" => "8/17"}
    }

    signup = %Draft{
      id: 2,
      kind: "signup_request",
      parsed: %{
        "note" => "想報名週一晚上",
        "student_id" => nil,
        "student_name" => nil,
        "line_user_id" => "Usample0000000000000000000000",
        "line_name" => "小美",
        "new" => true
      }
    }

    drafts = [makeup, signup]
    alt = Enum.map_join(drafts, "\n", &Assistant.draft_summary(&1, locale))

    [
      {"#{locale} draft carousel",
       [Client.flex_message(alt, Cards.draft_carousel(drafts, locale))]}
    ]
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
