defmodule Ganesha.Assistant.Turn do
  @moduledoc """
  What one agent turn produced (spec §4.2): the model's final text, the
  Drafts it created, the lookup cards it chose to show, and the quick-reply
  choices from `ask_teacher`.
  """

  @type t :: %__MODULE__{
          text: String.t() | nil,
          draft_ids: [integer()],
          cards: [Ganesha.Assistant.Task.card()],
          choices: [String.t()]
        }

  defstruct text: nil, draft_ids: [], cards: [], choices: []
end
