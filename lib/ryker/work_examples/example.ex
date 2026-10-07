defmodule Ryker.WorkExamples.Example do
  @moduledoc """
  One settled Work turn kept for training: the briefing the worker was given,
  what it did on the way, the result Ryker accepted and each one it refused,
  what happened next and what it cost, the words redacted
  (`Ryker.WorkExamples`).

  It names the turn (`turn_id`) and the request (`episode_id`) it was copied
  from without a foreign key, because the copy outlives both, and keeps a
  copy of the feedback people gave on that request
  (`Ryker.WorkExamples.Feedback`). A forgotten example keeps only its
  identity and scope: no bodies and no feedback.
  """
  use Ryker, :schema

  schema "work_examples" do
    field(:turn_id, :binary_id)
    field(:episode_id, :binary_id)
    field(:episode_ref, :string)
    # The identities of the messages the request was asked in (source kind,
    # source and native id): the keys a person forgetting one is matched by,
    # however many revisions it had.
    field(:source_identities, {:array, :string}, default: [])
    # Every message those messages' routing quoted, as
    # `Ryker.RoutingExamples.message_key/2`, and every conversation they came from.
    field(:message_keys, {:array, :string}, default: [])
    field(:conversation_refs, {:array, :string}, default: [])
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:repository_ref, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow])
    field(:execution_target, :string)
    # The exact prompt the worker was sent, and the context and schema beside it.
    field(:briefing, :string)
    field(:context, Ryker.CanonicalJSON.Type)
    field(:output_schema, Ryker.CanonicalJSON.Type)
    # What the worker did, in order: tool calls with their input and output,
    # and its progress notes, as Ryker recorded them.
    field(:trajectory, Ryker.CanonicalJSON.Type)
    # The result Ryker accepted, and each it refused before with why.
    field(:result, :string)
    field(:rejected_results, Ryker.CanonicalJSON.Type)
    field(:outcome, Ryker.CanonicalJSON.Type)
    field(:usage, Ryker.CanonicalJSON.Type)
    field(:settled_at, :utc_datetime_usec)
    field(:forgotten_at, :utc_datetime_usec)
    has_many(:feedback, Ryker.WorkExamples.Feedback, foreign_key: :example_id)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
