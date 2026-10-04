defmodule Ganesha.Assistant.Turn do
  @moduledoc """
  What one agent turn produced (spec §4.2): the model's final text, the
  Drafts it created or listed (via lookup `draft_ids`), the quick-reply
  choices from `ask_teacher`, and the id of the stored final reply (where
  the Drafts it sent are recorded).
  """

  @type t :: %__MODULE__{
          text: String.t() | nil,
          draft_ids: [integer()],
          choices: [String.t()],
          reply_message_id: integer() | nil
        }

  defstruct text: nil, draft_ids: [], choices: [], reply_message_id: nil
end
