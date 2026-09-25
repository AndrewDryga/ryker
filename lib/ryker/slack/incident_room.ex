defmodule Ryker.Slack.IncidentRoom do
  @moduledoc """
  One optional Slack incident-room artifact attached to an episode.

  The room owns only provisioning and presentation receipts. The linked episode
  remains the authority for investigation, waits, results, and delivery.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "slack_incident_rooms" do
    field(:ref, :string)
    belongs_to(:record, Ryker.State.Record)
    belongs_to(:source_episode, Ryker.Episodes.Episode)
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:status, Ecto.Enum, values: [:requested, :ready, :blocked, :closed])
    field(:workspace_ref, :string)
    field(:bot_user_ref, :string)
    field(:source_channel_ref, :string)
    field(:source_thread_ref, :string)
    field(:source_message_ref, :string)
    field(:requested_by_actor_ref, :string)
    field(:confirmation_ref, :string)
    field(:requested_at, :utc_datetime_usec)
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:repository_ref, :string)
    field(:repository_context, Ryker.CanonicalJSON.Type)
    # The environment of the conversation the room was opened from; the room's
    # investigation runs in it. Not a foreign key: history outlives settings.
    field(:environment_ref, :string)
    field(:title, :string)
    field(:prompt, :string)
    field(:channel_name, :string)
    field(:private, :boolean)
    field(:channel_ref, :string)

    field(:channel_state, Ecto.Enum,
      values: [:pending, :active, :archived, :deleted, :unavailable],
      default: :pending
    )

    field(:reconciled_channel_state, Ecto.Enum,
      values: [:pending, :active, :archived, :deleted, :unavailable],
      default: :pending
    )

    field(:channel_state_event_ref, :string)
    field(:channel_state_changed_at, :utc_datetime_usec)
    field(:channel_checked_at, :utc_datetime_usec)
    field(:root_message_ref, :string)
    field(:root_card_fingerprint, :string)
    field(:root_card_ui_revision, :integer, default: 0)
    field(:root_card_checked_at, :utc_datetime_usec)
    field(:handoff_message_ref, :string)
    field(:topic, :string)
    field(:invite_user_refs, {:array, :string}, default: [])
    field(:invite_user_group_refs, {:array, :string}, default: [])
    field(:audience_prepared_at, :utc_datetime_usec)
    field(:topic_prepared_at, :utc_datetime_usec)
    field(:root_pinned_at, :utc_datetime_usec)
    field(:attempt_count, :integer)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_owner, :string)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
