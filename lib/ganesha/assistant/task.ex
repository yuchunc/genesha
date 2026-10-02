defmodule Ganesha.Assistant.Task do
  @moduledoc """
  The behaviour every LINE assistant task and control tool implements
  (docs/superpowers/specs/2026-10-02-line-teacher-assistant-design.md §4.2).

  `:change` tasks implement `propose/2`, `apply/2` and `describe/2`;
  `:lookup` and `:control` tasks implement `answer/2`.

  - `propose/2` never writes. It resolves ids, checks the request against
    current data, and captures "before" values into `parsed`. Its
    `{:error, text}` goes back to the model as the tool result.
  - `apply/2` runs inside the transaction opened by
    `Ganesha.Assistant.confirm_draft/2` and only calls domain functions. It
    must not trust `parsed` beyond the keys its own `propose/2` wrote.
  - `describe/2` reads only `parsed`; it never queries current data.

  Never `alias` this module as `Task`: it would shadow Elixir's `Task`.
  """

  @type ctx :: %{thread: Ganesha.Assistant.Thread.t(), locale: String.t(), today: Date.t()}
  @type card :: {atom(), term()}

  @callback name() :: String.t()
  @callback kind() :: :lookup | :change | :control
  # description and input_schema only; the registry adds name and the shared fields
  @callback tool() :: %{description: String.t(), input_schema: map()}

  # :change tasks
  @callback propose(input :: map(), ctx()) ::
              {:ok, %{student_id: integer() | nil, parsed: map()}} | {:error, String.t()}
  @callback apply(parsed :: map(), confirmed_by :: String.t()) ::
              {:ok, {record_type :: String.t() | nil, record_id :: integer() | nil}}
              | {:error, term()}
  @callback describe(parsed :: map(), locale :: String.t()) :: %{
              title: String.t(),
              lines: [String.t()],
              changes: [
                {label :: String.t(), before :: String.t() | nil, after_value :: String.t()}
              ],
              web_path: String.t() | nil
            }

  # :lookup and :control tasks
  @callback answer(input :: map(), ctx()) ::
              {:ok,
               %{
                 required(:data) => String.t(),
                 optional(:card) => card(),
                 optional(:choices) => [String.t()]
               }}
              | {:error, String.t()}

  @optional_callbacks propose: 2, apply: 2, describe: 2, answer: 2
end
