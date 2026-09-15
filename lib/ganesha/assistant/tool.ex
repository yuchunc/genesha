defmodule Ganesha.Assistant.Tool do
  @moduledoc """
  A capability the agent loop can invoke. `call/2` returns `{content, draft_id}`:
  `content` is fed back to the model as the tool result; `draft_id` is the
  id of any `Ganesha.Assistant.Draft` the call created, or `nil` for a
  read-only tool.
  """

  @callback name() :: String.t()
  @callback schema() :: map()
  @callback call(input :: map(), thread :: Ganesha.Assistant.Thread.t()) ::
              {String.t(), integer() | nil}
end
