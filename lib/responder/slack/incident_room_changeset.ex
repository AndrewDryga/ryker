defmodule Responder.Slack.IncidentRoomChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.IncidentRoom
  alias Responder.Work.RepositoryContext

  @fields [
    :attempt_count,
    :audience_prepared_at,
    :bot_user_ref,
    :channel_name,
    :channel_ref,
    :channel_checked_at,
    :channel_state,
    :channel_state_changed_at,
    :channel_state_event_ref,
    :confirmation_ref,
    :episode_id,
    :handoff_message_ref,
    :id,
    :invite_user_group_refs,
    :invite_user_refs,
    :last_error_code,
    :last_error_detail,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :policy,
    :policy_digest,
    :private,
    :prompt,
    :record_id,
    :reconciled_channel_state,
    :ref,
    :repository_ref,
    :repository_context,
    :requested_at,
    :requested_by_actor_ref,
    :root_card_checked_at,
    :root_card_fingerprint,
    :root_card_ui_revision,
    :root_message_ref,
    :root_pinned_at,
    :source_channel_ref,
    :source_episode_id,
    :source_message_ref,
    :source_thread_ref,
    :status,
    :title,
    :topic,
    :topic_prepared_at,
    :workspace_ref
  ]

  @insert_required @fields --
                     [
                       :audience_prepared_at,
                       :channel_ref,
                       :channel_checked_at,
                       :channel_state_changed_at,
                       :channel_state_event_ref,
                       :episode_id,
                       :handoff_message_ref,
                       :last_error_code,
                       :last_error_detail,
                       :lease_expires_at,
                       :lease_owner,
                       :lease_ref,
                       :next_attempt_at,
                       :reconciled_channel_state,
                       :repository_context,
                       :root_card_checked_at,
                       :root_card_fingerprint,
                       :root_card_ui_revision,
                       :root_message_ref,
                       :root_pinned_at,
                       :source_thread_ref,
                       :topic_prepared_at
                     ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %IncidentRoom{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> validate_room()
  end

  @spec update(IncidentRoom.t(), map()) :: Ecto.Changeset.t()
  def update(%IncidentRoom{} = room, attributes) do
    room
    |> cast(attributes, @fields -- [:id, :record_id, :ref, :source_episode_id])
    |> validate_room()
  end

  defp validate_room(changeset) do
    changeset
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:policy, min: 1, max: 256)
    |> validate_format(:policy_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:repository_ref, min: 1, max: 256)
    |> validate_repository_context()
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:prompt, min: 1, max: 4_000)
    |> validate_length(:channel_name, min: 1, max: 80)
    |> validate_format(:channel_name, ~r/\A[a-z0-9_-]+\z/)
    |> validate_length(:topic, min: 1, max: 250)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:root_card_ui_revision, greater_than_or_equal_to: 0)
    |> validate_format(:root_card_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_inclusion(:channel_state, [
      :pending,
      :active,
      :archived,
      :deleted,
      :unavailable
    ])
    |> validate_inclusion(:reconciled_channel_state, [
      :pending,
      :active,
      :archived,
      :deleted,
      :unavailable
    ])
    |> unique_constraint(:ref)
    |> unique_constraint(:record_id)
    |> unique_constraint(:episode_id)
    |> unique_constraint(:channel_name)
    |> unique_constraint(:channel_ref)
    |> foreign_key_constraint(:record_id)
    |> foreign_key_constraint(:source_episode_id)
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:status, name: :slack_incident_room_valid)
    |> check_constraint(:repository_context,
      name: :slack_incident_room_repository_context_valid
    )
  end

  defp validate_repository_context(changeset) do
    validate_change(changeset, :repository_context, fn :repository_context, value ->
      case RepositoryContext.restore(value, get_field(changeset, :repository_ref)) do
        {:ok, _context} -> []
        {:error, :invalid} -> [repository_context: "is not a bounded repository set"]
      end
    end)
  end
end
