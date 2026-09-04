defmodule Responder.State.MemoryEntry do
  @moduledoc """
  One operator-confirmed operational mapping.

  Entries are hints with explicit scope, visibility, provenance, and expiry.
  They are never evidence, executable configuration, or authority.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "operational_memory_entries" do
    belongs_to(:offer_record, Responder.State.Record)
    belongs_to(:cutover_item, Responder.Cutover.Item)
    field(:ref, :string)

    field(:kind, Ecto.Enum,
      values: [:alias, :repository_binding, :evidence_route, :entity_relationship]
    )

    field(:status, Ecto.Enum, values: [:active, :superseded, :deleted, :expired])
    field(:workspace_ref, :string)
    field(:scope_kind, Ecto.Enum, values: [:conversation, :repository, :workspace])
    field(:scope_ref, :string)
    field(:visibility, Ecto.Enum, values: [:conversation, :workspace])
    field(:subject, :string)
    field(:payload, Responder.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)
    field(:confirmed_by_actor_ref, :string)
    field(:confirmation_ref, :string)
    field(:confirmed_at, :utc_datetime_usec)
    field(:source_transport, :string)
    field(:source_conversation_ref, :string)
    field(:source_thread_ref, :string)
    field(:source_message_ref, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:recall_count, :integer, default: 0)
    field(:last_recalled_at, :utc_datetime_usec)
    field(:last_reviewed_at, :utc_datetime_usec)
    field(:edited_at, :utc_datetime_usec)
    field(:edited_by_actor_ref, :string)
    field(:edit_review_ref, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
