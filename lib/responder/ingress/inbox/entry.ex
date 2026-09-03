defmodule Responder.Ingress.Inbox.Entry do
  @moduledoc """
  One immutable source input plus its eventual admission decision.

  The input columns never change. Admission fills the decision columns and
  optional episode link exactly once in a later transaction.
  """

  use Ecto.Schema

  alias Responder.CanonicalJSON.Type, as: CanonicalJSONType
  alias Responder.Episodes.Episode

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "ingress_inbox_entries" do
    field(:dedupe_key, :string)
    field(:event_fingerprint, :string)
    field(:source_kind, :string)
    field(:source_ref, :string)
    field(:event_ref, :string)
    field(:event_kind, Ecto.Enum, values: [:message, :edit, :delete, :event])
    field(:native_input_id, :string)
    field(:source_item_ref, :string)
    field(:actor_kind, Ecto.Enum, values: [:user, :app, :bot, :system])
    field(:actor_ref, :string)
    field(:source_capabilities, CanonicalJSONType)
    field(:destination_transport, :string)
    field(:destination_conversation_ref, :string)
    field(:destination_thread_ref, :string)
    field(:revision, :integer)
    field(:occurred_at, :utc_datetime_usec)
    field(:occurred_at_source, Ecto.Enum, values: [:source, :ingress])
    field(:content, CanonicalJSONType)
    field(:admission_context, CanonicalJSONType)
    field(:admission_context_fingerprint, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow], default: :live)
    field(:work_profile, CanonicalJSONType)
    field(:work_policy, :string)
    field(:work_policy_digest, :string)
    field(:repository_ref, :string)

    field(:status, Ecto.Enum,
      values: [:pending, :blocked, :decided, :superseded],
      default: :pending
    )

    field(:decision_ref, :string)
    field(:decision_fingerprint, :string)

    field(:decision_action, Ecto.Enum,
      values: [:start_episode, :continue_episode, :reply, :react, :ignore]
    )

    field(:decision_document, CanonicalJSONType)
    field(:attempt_count, :integer, default: 0)
    field(:execution_generation, :integer, default: 1)
    field(:validation_generation, :integer, default: 1)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    field(:operational_pruned_at, :utc_datetime_usec)
    belongs_to(:episode, Episode)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
