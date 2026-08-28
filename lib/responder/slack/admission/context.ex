defmodule Responder.Slack.Admission.Context do
  @moduledoc """
  Frozen input and bounded candidate set supplied to one model decision.
  """

  alias Responder.Slack.Admission.Candidate
  alias Responder.Slack.Inbox.Entry
  alias Responder.Slack.Input

  @enforce_keys [:built_at, :candidates, :conversation_episode_count, :input, :input_entry]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          built_at: DateTime.t(),
          candidates: [Candidate.t()],
          conversation_episode_count: non_neg_integer(),
          input: Input.t(),
          input_entry: Entry.t()
        }

  @spec for_model(t()) :: map()
  def for_model(%__MODULE__{} = context) do
    %{
      "candidates" => Enum.map(context.candidates, &Candidate.for_model/1),
      "input" => Input.model_document(context.input)
    }
  end
end
