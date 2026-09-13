defmodule Ryker.Repo.Migrations.CreateEpisodeWorkActivity do
  use Ecto.Migration

  def change do
    alter table(:episode_work_sessions) do
      add(:activity_cursor, :bigint, null: false, default: 0)
      add(:activity_sync_pending, :boolean, null: false, default: false)
    end

    alter table(:episode_work_turns) do
      add(:validation_history, :text, null: false, default: "[]")
    end

    alter table(:coop_session_placements) do
      add(:last_acked_session_event_sequence, :bigint, null: false, default: 0)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_activity_cursor_valid,
        check: "activity_cursor >= 0"
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_validation_history_valid,
        check:
          "jsonb_typeof(validation_history::jsonb) = 'array' AND octet_length(validation_history) <= 262144"
      )
    )

    create(
      constraint(
        :coop_session_placements,
        :coop_session_placement_session_event_cursor_valid,
        check: "last_acked_session_event_sequence >= 0"
      )
    )

    execute(
      "DROP INDEX #{qualified("coop_worker_events_placement_id_sequence_index")}",
      """
      CREATE UNIQUE INDEX coop_worker_events_placement_id_sequence_index
        ON #{qualified("coop_worker_events")} (placement_id, sequence)
      """
    )

    execute(
      """
      CREATE UNIQUE INDEX coop_worker_events_placement_id_sequence_index
        ON #{qualified("coop_worker_events")}
        (placement_id, (kind = 'session_event'), sequence)
      """,
      "DROP INDEX #{qualified("coop_worker_events_placement_id_sequence_index")}"
    )

    create table(:episode_work_activity, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(
        :session_id,
        references(:episode_work_sessions,
          type: :uuid,
          on_delete: :restrict,
          with: [episode_id: :episode_id],
          name: :episode_work_activity_session_episode_fkey
        ),
        null: false
      )

      add(:remote_event_id, :text, null: false)
      add(:remote_session_id, :text, null: false)
      add(:coop_turn_id, :text)
      add(:sequence, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:version, :integer, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:payload, :text, null: false)
      add(:payload_fingerprint, :text, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:episode_operator_reviews, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:semantic_version, :bigint, null: false)
      add(:actor_ref, :text, null: false)
      add(:note, :text, null: false, default: "")
      add(:reviewed_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:episode_operator_reviews, [:episode_id, :semantic_version]))
    create(index(:episode_operator_reviews, [:reviewed_at]))

    create(
      constraint(:episode_operator_reviews, :episode_operator_review_valid,
        check:
          "semantic_version >= 0 AND char_length(actor_ref) BETWEEN 1 AND 1024 AND octet_length(note) <= 2048"
      )
    )

    create(unique_index(:episode_work_activity, [:session_id, :remote_session_id, :sequence]))
    create(unique_index(:episode_work_activity, [:remote_event_id]))
    create(index(:episode_work_activity, [:episode_id, :occurred_at, :sequence]))
    create(index(:episode_work_activity, [:coop_turn_id, :sequence]))

    create(
      constraint(:episode_work_activity, :episode_work_activity_identity_valid,
        check: """
        sequence > 0 AND version > 0 AND version <= 65535 AND
        char_length(remote_event_id) BETWEEN 1 AND 512 AND
        char_length(remote_session_id) BETWEEN 1 AND 512 AND
        char_length(kind) BETWEEN 1 AND 128 AND
        (coop_turn_id IS NULL OR char_length(coop_turn_id) BETWEEN 1 AND 512) AND
        char_length(payload_fingerprint) = 64
        """
      )
    )

    execute(
      """
      ALTER TABLE #{qualified("coop_worker_events")}
        DROP CONSTRAINT coop_worker_event_identity_valid,
        ADD CONSTRAINT coop_worker_event_identity_valid CHECK (
          placement_generation > 0 AND sequence > 0 AND
          kind IN (
            'operation', 'session', 'turn', 'candidate', 'validation', 'workspace',
            'checkpoint', 'capacity', 'session_event'
          ) AND char_length(payload_fingerprint) = 64
        )
      """,
      """
      ALTER TABLE #{qualified("coop_worker_events")}
        DROP CONSTRAINT coop_worker_event_identity_valid,
        ADD CONSTRAINT coop_worker_event_identity_valid CHECK (
          placement_generation > 0 AND sequence > 0 AND
          kind IN (
            'operation', 'session', 'turn', 'candidate', 'validation', 'workspace',
            'checkpoint', 'capacity'
          ) AND char_length(payload_fingerprint) = 64
        )
      """
    )

    execute(
      "SELECT 1",
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM #{qualified("episode_work_activity")} LIMIT 1) OR
           EXISTS (SELECT 1 FROM #{qualified("episode_operator_reviews")} LIMIT 1) OR
           EXISTS (
             SELECT 1 FROM #{qualified("episode_work_sessions")}
             WHERE activity_cursor > 0 OR activity_sync_pending
             LIMIT 1
           ) OR
           EXISTS (
             SELECT 1 FROM #{qualified("episode_work_turns")}
             WHERE validation_history <> '[]'
             LIMIT 1
           ) OR
           EXISTS (
             SELECT 1 FROM #{qualified("coop_session_placements")}
             WHERE last_acked_session_event_sequence > 0
             LIMIT 1
           ) THEN
          RAISE EXCEPTION 'episode work activity has data and cannot be rolled back safely';
        END IF;
      END
      $$
      """
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
