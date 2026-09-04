defmodule Responder.State.Behavior do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "operator_behaviors" do
    belongs_to(:offer_record, Responder.State.Record)
    belongs_to(:cutover_item, Responder.Cutover.Item)
    field(:ref, :string)
    field(:kind, Ecto.Enum, values: [:preference, :guidance, :standing_assignment])
    field(:status, Ecto.Enum, values: [:active, :disabled, :superseded, :deleted, :expired])
    field(:workspace_ref, :string)
    field(:scope_kind, Ecto.Enum, values: [:workspace, :conversation, :repository, :operator])
    field(:scope_ref, :string)
    field(:identity_key, :string)
    field(:payload, Responder.CanonicalJSON.Type)
    field(:confirmed_by_actor_ref, :string)
    field(:confirmation_ref, :string)
    field(:confirmed_at, :utc_datetime_usec)
    field(:source_transport, :string)
    field(:source_conversation_ref, :string)
    field(:source_thread_ref, :string)
    field(:source_message_ref, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:use_count, :integer, default: 0)
    field(:last_used_at, :utc_datetime_usec)
    field(:last_reviewed_at, :utc_datetime_usec)
    field(:edited_at, :utc_datetime_usec)
    field(:edited_by_actor_ref, :string)
    field(:edit_review_ref, :string)
    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
