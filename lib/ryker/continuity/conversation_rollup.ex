defmodule Ryker.Continuity.ConversationRollup do
  @moduledoc false
  use Ryker, :schema

  schema "conversation_rollups" do
    field(:ref, :string)
    field(:workspace_ref, :string)
    field(:scope_kind, Ecto.Enum, values: [:conversation, :repository])
    field(:scope_ref, :string)
    field(:repository_ref, :string)
    field(:visibility, Ecto.Enum, values: [:public, :private, :direct, :conversation])
    field(:period_start, :utc_datetime_usec)
    field(:period_end, :utc_datetime_usec)
    field(:state, Ryker.CanonicalJSON.Type)
    field(:source_dependencies, Ryker.CanonicalJSON.Type, default: [])
    field(:state_fingerprint, :string)
    field(:source_refs, Ryker.CanonicalJSON.Type)
    field(:source_scopes, Ryker.CanonicalJSON.Type)
    field(:source_count, :integer)
    field(:expires_at, :utc_datetime_usec)
    field(:recall_count, :integer, default: 0)
    field(:last_recalled_at, :utc_datetime_usec)
    timestamps()
  end
end
