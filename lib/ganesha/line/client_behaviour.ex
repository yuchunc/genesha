defmodule Ganesha.Line.ClientBehaviour do
  @moduledoc "Contract shared by `Ganesha.Line.Client` and `Ganesha.Line.Client.Mock`."

  @callback reply(reply_token :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback push(to :: String.t(), messages :: [map()]) :: :ok | {:error, term()}
  @callback get_group_member(group_id :: String.t(), user_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
end
