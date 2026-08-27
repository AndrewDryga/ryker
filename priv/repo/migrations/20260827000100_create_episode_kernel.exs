defmodule Responder.Repo.Migrations.CreateEpisodeKernel do
  use Ecto.Migration

  def change do
    create table(:episode_kernel_episodes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:key, :text, null: false)
      add(:state, :text, null: false)
      add(:owner_kind, :text)
      add(:owner_ref, :text)
      add(:owner_deadline_at, :utc_datetime_usec)
      add(:destination_transport, :text, null: false)
      add(:destination_conversation_ref, :text, null: false)
      add(:destination_thread_ref, :text)

      add(
        :linked_episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict)
      )

      add(:semantic_version, :bigint, null: false, default: 0)
      add(:next_sequence, :bigint, null: false, default: 1)
      add(:input_revisions, :map, null: false, default: %{})
      add(:active_input_refs, {:array, :text}, null: false, default: [])
      add(:queued_input_refs, {:array, :text}, null: false, default: [])
      add(:queued_input_order_keys, {:array, :text}, null: false, default: [])

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:episode_kernel_episodes, [:key]))
    create(index(:episode_kernel_episodes, [:linked_episode_id]))

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_history_not_self,
        check: "linked_episode_id IS NULL OR linked_episode_id <> id"
      )
    )

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_episode_key_not_empty,
        check: "char_length(key) > 0"
      )
    )

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_destination_not_empty,
        check:
          "char_length(destination_transport) > 0 AND " <>
            "char_length(destination_conversation_ref) > 0"
      )
    )

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_versions_nonnegative,
        check: "semantic_version >= 0 AND next_sequence > 0"
      )
    )

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_owner_matches_state,
        check: """
        (state IN ('complete', 'cancelled') AND owner_kind IS NULL AND owner_ref IS NULL AND owner_deadline_at IS NULL)
        OR
        (state = 'working' AND owner_kind IN ('turn', 'delivery') AND char_length(owner_ref) > 0 AND owner_deadline_at IS NULL)
        OR
        (state = 'waiting_for_input' AND owner_kind = 'input' AND char_length(owner_ref) > 0 AND owner_deadline_at IS NULL)
        OR
        (state = 'waiting_for_event' AND owner_kind = 'event' AND char_length(owner_ref) > 0 AND owner_deadline_at IS NOT NULL)
        """
      )
    )

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_inputs_match_owner,
        check: """
        NOT (active_input_refs && queued_input_refs)
        AND cardinality(queued_input_refs) = cardinality(queued_input_order_keys)
        AND (owner_kind IS DISTINCT FROM 'delivery' OR cardinality(active_input_refs) = 0)
        AND (state NOT IN ('waiting_for_input', 'waiting_for_event') OR cardinality(active_input_refs) = 0)
        AND (state NOT IN ('complete', 'cancelled') OR (cardinality(active_input_refs) = 0 AND cardinality(queued_input_refs) = 0))
        """
      )
    )

    create table(:episode_kernel_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:sequence, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:dedupe_key, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:payload, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(unique_index(:episode_kernel_events, [:episode_id, :sequence]))
    create(unique_index(:episode_kernel_events, [:episode_id, :dedupe_key]))

    create(
      constraint(:episode_kernel_events, :episode_kernel_event_sequence_positive,
        check: "sequence > 0"
      )
    )

    create(
      constraint(:episode_kernel_events, :episode_kernel_event_identity_valid,
        check: "char_length(dedupe_key) > 0 AND char_length(fingerprint) = 64"
      )
    )

    create(
      constraint(:episode_kernel_events, :episode_kernel_event_kind_valid,
        check: """
        kind IN (
          'input_admitted', 'owner_transferred', 'input_wait_started',
          'event_wait_started', 'wait_resumed', 'result_accepted',
          'delivery_confirmed', 'episode_cancelled'
        )
        """
      )
    )
  end
end
