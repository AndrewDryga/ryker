defmodule Ryker.State.ConversationKnowledge do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: false}
  schema "conversation_knowledge" do
    field(:scope_key, :string)
    field(:topic_key, :string)
    field(:anchor_keys, {:array, :string}, default: [])
    field(:transport, :string)
    field(:workspace_ref, :string)
    field(:conversation_ref, :string)
    field(:repository_ref, :string)
    field(:visibility, Ecto.Enum, values: [:public, :private, :direct, :conversation])
    field(:state, Ryker.CanonicalJSON.Type)
    field(:version, :integer)
    field(:source_generation, :integer)
    field(:source_dependencies, Ryker.CanonicalJSON.Type)
    field(:source_input_id, :binary_id)
    field(:source_episode_id, :binary_id)
    field(:latest_source_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
