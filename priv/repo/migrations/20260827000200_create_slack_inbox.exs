defmodule Ryker.Repo.Migrations.CreateSlackInbox do
  use Ecto.Migration

  def change do
    create table(:slack_inbox_entries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:dedupe_key, :text, null: false)
      add(:event_fingerprint, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:channel_ref, :text, null: false)
      add(:event_ref, :text, null: false)
      add(:event_kind, :text, null: false)
      add(:message_ref, :text, null: false)
      add(:thread_ref, :text)
      add(:actor_kind, :text, null: false)
      add(:actor_ref, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:content, :text, null: false)
      add(:status, :text, null: false)
      add(:decision_ref, :text)
      add(:decision_fingerprint, :text)
      add(:decision_action, :text)
      add(:decision_document, :text)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:slack_inbox_entries, [:dedupe_key]))
    create(unique_index(:slack_inbox_entries, [:decision_ref], where: "decision_ref IS NOT NULL"))
    create(index(:slack_inbox_entries, [:workspace_ref, :channel_ref, :occurred_at]))
    create(index(:slack_inbox_entries, [:episode_id, :occurred_at]))

    create(
      constraint(:slack_inbox_entries, :slack_inbox_refs_not_empty,
        check: """
        char_length(dedupe_key) > 0 AND char_length(event_ref) > 0
        AND char_length(workspace_ref) > 0 AND char_length(channel_ref) > 0
        AND char_length(message_ref) > 0 AND char_length(actor_ref) > 0
        """
      )
    )

    create(
      constraint(:slack_inbox_entries, :slack_inbox_event_identity_valid,
        check: "char_length(event_fingerprint) = 64 AND revision > 0"
      )
    )

    create(
      constraint(:slack_inbox_entries, :slack_inbox_event_shape_valid,
        check: """
        event_kind IN ('message', 'edit', 'delete')
        AND actor_kind IN ('user', 'app', 'bot')
        """
      )
    )

    create(
      constraint(:slack_inbox_entries, :slack_inbox_decision_matches_status,
        check: """
        (
          status = 'pending'
          AND decision_ref IS NULL AND decision_fingerprint IS NULL
          AND decision_action IS NULL AND decision_document IS NULL AND episode_id IS NULL
        )
        OR
        (
          status = 'decided'
          AND char_length(decision_ref) > 0 AND char_length(decision_fingerprint) = 64
          AND decision_action IN ('start_episode', 'continue_episode', 'reply', 'react', 'ignore')
          AND decision_document IS NOT NULL
          AND (
            (decision_action IN ('react', 'ignore') AND episode_id IS NULL)
            OR
            (decision_action IN ('start_episode', 'continue_episode', 'reply') AND episode_id IS NOT NULL)
          )
        )
        """
      )
    )
  end
end
