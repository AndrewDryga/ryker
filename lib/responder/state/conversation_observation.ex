defmodule Responder.State.ConversationObservation do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "conversation_observations" do
    field(:identity_key, :string)
    field(:transport, :string)
    field(:workspace_ref, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:repository_ref, :string)
    field(:visibility, Ecto.Enum, values: [:public, :private, :direct, :conversation])
    field(:source_input_id, :binary_id)
    field(:source_episode_id, :binary_id)
    field(:source_message_ref, :string)
    field(:source_result_ref, :string)
    field(:source_fingerprint, :string)
    field(:actor_ref, :string)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow])
    field(:revision, :integer)
    field(:occurred_at, :utc_datetime_usec)
    field(:note, Responder.CanonicalJSON.Type)
    timestamps(type: :utc_datetime_usec)
  end
end
