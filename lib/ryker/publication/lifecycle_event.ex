defmodule Ryker.Publication.LifecycleEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_publication_lifecycle_events" do
    belongs_to(:publication, Ryker.Publication.Publication)
    belongs_to(:episode, Ryker.Episodes.Episode)

    field(:ref, :string)
    field(:kind, :string)
    field(:state, :string)
    field(:summary, :string)
    field(:observation, Ryker.CanonicalJSON.Type)
    field(:source_transport, :string)
    field(:source_conversation_ref, :string)
    field(:source_item_ref, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:wakeup_state, Ecto.Enum, values: [:none, :pending, :admitted], default: :none)

    field(:delivery_state, Ecto.Enum, values: [:pending, :delivered], default: :pending)
    field(:delivery_ref, :string)
    field(:delivery_receipt, Ryker.CanonicalJSON.Type)
    field(:delivery_receipt_fingerprint, :string)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end
end
