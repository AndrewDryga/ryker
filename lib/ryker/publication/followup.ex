defmodule Ryker.Publication.Followup do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_publication_followups" do
    belongs_to(:publication, Ryker.Publication.Publication)
    belongs_to(:episode, Ryker.Episodes.Episode)

    field(:pr_state, Ecto.Enum,
      values: [:open, :closed, :merged, :stale, :expired],
      default: :open
    )

    field(:checks_state, Ecto.Enum,
      values: [:unknown, :none, :pending, :passing, :failing],
      default: :unknown
    )

    field(:checks_total, :integer, default: 0)
    field(:checks_passed, :integer, default: 0)
    field(:checks_failed, :integer, default: 0)
    field(:checks_url, :string)
    field(:merge_sha, :string)
    field(:merged_at, :utc_datetime_usec)
    field(:verification_turn_ref, :string)
    field(:verification_event_ref, :string)
    field(:verification_sequence, :integer)
    field(:verified_at, :utc_datetime_usec)

    field(:next_poll_at, :utc_datetime_usec)
    field(:deadline_at, :utc_datetime_usec)
    field(:failure_count, :integer, default: 0)
    field(:last_error, :string)
    field(:last_event_key, :string)

    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
