defmodule Responder.Repo.Migrations.CreateGenericIngress do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified_slack_table()} LIMIT 1) THEN
        RAISE EXCEPTION 'cannot replace non-empty slack_inbox_entries';
      END IF;
    END
    $$
    """)

    drop(table(:slack_inbox_entries))

    create table(:ingress_inbox_entries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:dedupe_key, :text, null: false)
      add(:event_fingerprint, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:source_ref, :text, null: false)
      add(:source_item_ref, :text)
      add(:event_ref, :text, null: false)
      add(:event_kind, :text, null: false)
      add(:native_input_id, :text, null: false)
      add(:actor_kind, :text, null: false)
      add(:actor_ref, :text, null: false)
      add(:can_react, :boolean, null: false)
      add(:destination_transport, :text, null: false)
      add(:destination_conversation_ref, :text, null: false)
      add(:destination_thread_ref, :text)
      add(:revision, :bigint, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:occurred_at_source, :text, null: false, default: "source")
      add(:content, :text, null: false)
      add(:admission_context, :text)
      add(:admission_context_fingerprint, :text)
      add(:status, :text, null: false)
      add(:decision_ref, :text)
      add(:decision_fingerprint, :text)
      add(:decision_action, :text)
      add(:decision_document, :text)
      add(:attempt_count, :bigint, null: false, default: 0)
      add(:execution_generation, :bigint, null: false, default: 1)
      add(:validation_generation, :bigint, null: false, default: 1)
      add(:lease_ref, :text)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:last_error_detail, :text)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict)
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ingress_inbox_entries, [:dedupe_key]))

    create(
      unique_index(:ingress_inbox_entries, [:decision_ref], where: "decision_ref IS NOT NULL")
    )

    create(index(:ingress_inbox_entries, [:source_kind, :source_ref, :occurred_at]))
    create(index(:ingress_inbox_entries, [:episode_id, :occurred_at]))

    create(
      index(
        :ingress_inbox_entries,
        [:status, :next_attempt_at, :lease_expires_at, :inserted_at, :id],
        name: :ingress_inbox_claimable
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_refs_not_empty,
        check: """
        char_length(dedupe_key) > 0 AND char_length(event_ref) > 0
        AND char_length(source_ref) > 0 AND char_length(native_input_id) > 0
        AND char_length(actor_ref) > 0 AND char_length(destination_transport) > 0
        AND char_length(destination_conversation_ref) > 0
        """
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_event_identity_valid,
        check: "char_length(event_fingerprint) = 64 AND revision > 0"
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_event_shape_valid,
        check: """
        source_kind IN ('slack', 'webhook')
        AND event_kind IN ('message', 'edit', 'delete', 'event')
        AND actor_kind IN ('user', 'app', 'bot', 'system')
        """
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_occurrence_source_valid,
        check: "occurred_at_source IN ('source', 'ingress')"
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_reaction_target_valid,
        check:
          "NOT can_react OR (source_item_ref IS NOT NULL AND char_length(source_item_ref) > 0)"
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_execution_generation_valid,
        check: "execution_generation > 0"
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_validation_generation_valid,
        check: "validation_generation > 0"
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_admission_context_valid,
        check: """
        (admission_context IS NULL AND admission_context_fingerprint IS NULL)
        OR
        (admission_context IS NOT NULL AND char_length(admission_context_fingerprint) = 64)
        """
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_execution_custody_valid,
        check: """
        attempt_count >= 0
        AND (
          (lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR
          (
            status = 'pending'
            AND char_length(lease_ref) > 0
            AND char_length(lease_owner) > 0
            AND lease_expires_at IS NOT NULL
          )
        )
        AND (status = 'pending' OR next_attempt_at IS NULL)
        """
      )
    )

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_decision_matches_status,
        check: """
        (
          status = 'pending'
          AND decision_ref IS NULL AND decision_fingerprint IS NULL
          AND decision_action IS NULL AND decision_document IS NULL AND episode_id IS NULL
        )
        OR
        (
          status = 'blocked'
          AND decision_ref IS NULL AND decision_fingerprint IS NULL
          AND decision_action IS NULL AND decision_document IS NULL AND episode_id IS NULL
          AND char_length(last_error_code) > 0 AND char_length(last_error_detail) > 0
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
        OR
        (
          status = 'superseded'
          AND char_length(decision_ref) > 0 AND char_length(decision_fingerprint) = 64
          AND decision_action IN ('start_episode', 'continue_episode', 'reply', 'react', 'ignore')
          AND decision_document IS NOT NULL AND episode_id IS NOT NULL
          AND last_error_code = 'stale_input_revision'
          AND char_length(last_error_detail) > 0
        )
        """
      )
    )
  end

  def down do
    drop(table(:ingress_inbox_entries))

    execute("RAISE EXCEPTION 'generic ingress cannot be downgraded to the Slack-only inbox'")
  end

  defp qualified_slack_table do
    case prefix() do
      nil -> "slack_inbox_entries"
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".slack_inbox_entries)
    end
  end
end
