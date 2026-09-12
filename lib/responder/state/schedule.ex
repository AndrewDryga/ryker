defmodule Responder.State.Schedule do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_schedules" do
    belongs_to(:offer_record, Responder.State.Record)
    belongs_to(:source_episode, Responder.Episodes.Episode)
    belongs_to(:cutover_item, Responder.Cutover.Item)

    field(:ref, :string)
    field(:status, Ecto.Enum, values: [:active, :paused, :completed, :expired, :deleted])
    field(:title, :string)
    field(:task, :string)
    field(:recurrence, Responder.CanonicalJSON.Type)
    field(:timezone, :string)
    field(:authority, Ecto.Enum, values: [:read_only, :repository_write, :governed_operation])
    field(:repository, :string)
    field(:destination_transport, :string)
    field(:destination_conversation_ref, :string)
    field(:destination_thread_ref, :string)
    field(:confirmed_by_actor_ref, :string)
    field(:confirmation_ref, :string)
    field(:confirmed_at, :utc_datetime_usec)
    field(:next_occurrence_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:failure_count, :integer, default: 0)
    field(:last_error, :string)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:revision, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end
end
