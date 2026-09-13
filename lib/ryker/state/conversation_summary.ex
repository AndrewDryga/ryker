defmodule Ryker.State.ConversationSummary do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "conversation_summaries" do
    field(:ref, :string)
    field(:identity_key, :string)
    field(:transport, :string)
    field(:workspace_ref, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:repository_ref, :string)
    field(:visibility, Ecto.Enum, values: [:public, :private, :direct, :conversation])
    field(:state, Ryker.CanonicalJSON.Type)
    field(:source_dependencies, Ryker.CanonicalJSON.Type, default: [])
    field(:state_fingerprint, :string)
    field(:source_episode_id, :binary_id)
    field(:source_turn_id, :binary_id)
    field(:source_result_ref, :string)
    field(:source_message_ref, :string)
    field(:compaction_error_code, :string)
    field(:compaction_retry_at, :utc_datetime_usec)
    field(:recall_count, :integer, default: 0)
    field(:last_recalled_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
