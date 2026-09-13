defmodule Ganesha.Assistant.Provider do
  @moduledoc """
  Swappable LLM backend for `Ganesha.Assistant.Agent`. `Ganesha.Assistant.Provider.Anthropic`
  is the production adapter (Task 13); `Ganesha.Assistant.Provider.Mock` is
  test-only. Configured via `config :ganesha, :assistant, provider: ...`.
  """

  @callback complete(messages :: [map()], tools :: [map()], opts :: keyword()) ::
              {:ok, %{text: String.t() | nil, tool_calls: [map()]}} | {:error, term()}
end
