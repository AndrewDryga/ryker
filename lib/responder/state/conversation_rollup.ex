defmodule Responder.State.ConversationRollup do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "conversation_rollups" do
    field(:ref, :string)
    field(:workspace_ref, :string)
    field(:scope_kind, Ecto.Enum, values: [:conversation, :repository])
    field(:scope_ref, :string)
    field(:repository_ref, :string)
    field(:visibility, Ecto.Enum, values: [:public, :private, :direct, :conversation])
    field(:period_start, :utc_datetime_usec)
    field(:period_end, :utc_datetime_usec)
    field(:state, Responder.CanonicalJSON.Type)
    field(:state_fingerprint, :string)
    field(:source_refs, Responder.CanonicalJSON.Type)
    field(:source_scopes, Responder.CanonicalJSON.Type)
    field(:source_count, :integer)
    field(:expires_at, :utc_datetime_usec)
    field(:recall_count, :integer, default: 0)
    field(:last_recalled_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
