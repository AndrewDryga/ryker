defmodule Ryker.State.EventSubscription do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_event_subscriptions" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    belongs_to(:record, Ryker.State.Record)

    field(:ref, :string)
    field(:status, Ecto.Enum, values: [:active, :resolved, :timed_out, :cancelled])
    field(:source_kind, :string)
    field(:matcher, Ryker.CanonicalJSON.Type)
    field(:cursor, Ryker.CanonicalJSON.Type)
    field(:poll_after, :utc_datetime_usec)
    field(:deadline_at, :utc_datetime_usec)
    field(:last_observation, Ryker.CanonicalJSON.Type)
    field(:last_observed_at, :utc_datetime_usec)

    field(:resolution_kind, Ecto.Enum,
      values: [:input, :poll_fallback, :timer, :deadline, :cancelled]
    )

    field(:revision, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end
end
