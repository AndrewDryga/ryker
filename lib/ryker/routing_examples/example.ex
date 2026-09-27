defmodule Ryker.RoutingExamples.Example do
  @moduledoc """
  One routing decision kept for training: the exact prompt routing sent and
  the model's answer, both redacted, what the decision was, what happened
  next and what it cost (`Ryker.RoutingExamples`).

  It names the message (`input_id`) and the request (`episode_id`) it was
  copied from without a foreign key, because the copy outlives both. A
  forgotten example keeps only its identity and scope, and no bodies.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "routing_examples" do
    field(:input_id, :binary_id)
    field(:episode_id, :binary_id)
    field(:episode_ref, :string)
    # The message's own identity (source kind, source and native id): the key
    # a person forgetting it is matched by, however many revisions it had.
    field(:source_identity, :string)
    # Every message the prompt quotes, its own included, as
    # `Ryker.RoutingExamples.message_key/2`; and every conversation they came from.
    field(:message_keys, {:array, :string}, default: [])
    field(:conversation_refs, {:array, :string}, default: [])
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:repository_ref, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow])
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:execution_target, :string)
    field(:prompt, :string)
    field(:output_schema, Ryker.CanonicalJSON.Type)
    field(:answer, :string)
    field(:decision, Ryker.CanonicalJSON.Type)
    field(:outcome, Ryker.CanonicalJSON.Type)
    field(:usage, Ryker.CanonicalJSON.Type)
    field(:decided_at, :utc_datetime_usec)
    field(:forgotten_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
