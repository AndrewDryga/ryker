defmodule Responder.Repo.Migrations.CreateConversationContinuity do
  use Ecto.Migration

  def change do
    alter table(:operational_memory_entries) do
      add(:last_reviewed_at, :utc_datetime_usec)
      add(:edited_at, :utc_datetime_usec)
      add(:edited_by_actor_ref, :text)
      add(:edit_review_ref, :text)
    end

    alter table(:operator_behaviors) do
      add(:last_reviewed_at, :utc_datetime_usec)
      add(:edited_at, :utc_datetime_usec)
      add(:edited_by_actor_ref, :text)
      add(:edit_review_ref, :text)
    end

    alter table(:slack_channel_memberships) do
      add(:external_shared, :boolean)
      add(:private, :boolean)
    end

    alter table(:episode_work_turns) do
      add(:final_preflight_continuity_sha256, :text)
    end

    execute(
      """
      ALTER TABLE episode_work_turns
      DROP CONSTRAINT episode_work_turn_final_preflight_valid,
      ADD CONSTRAINT episode_work_turn_final_preflight_valid CHECK (
        (
          final_preflight_candidate_sha256 IS NULL AND
          final_preflight_continuity_sha256 IS NULL AND
          final_preflight_ledger_sha256 IS NULL AND
          final_preflight_semantic_version IS NULL
        ) OR (
          final_preflight_candidate_sha256 ~ '^[0-9a-f]{64}$' AND
          final_preflight_continuity_sha256 ~ '^[0-9a-f]{64}$' AND
          final_preflight_ledger_sha256 ~ '^[0-9a-f]{64}$' AND
          final_preflight_semantic_version >= 0
        )
      )
      """,
      """
      ALTER TABLE episode_work_turns
      DROP CONSTRAINT episode_work_turn_final_preflight_valid,
      ADD CONSTRAINT episode_work_turn_final_preflight_valid CHECK (
        (
          final_preflight_candidate_sha256 IS NULL AND
          final_preflight_ledger_sha256 IS NULL AND
          final_preflight_semantic_version IS NULL
        ) OR (
          final_preflight_candidate_sha256 ~ '^[0-9a-f]{64}$' AND
          final_preflight_ledger_sha256 ~ '^[0-9a-f]{64}$' AND
          final_preflight_semantic_version >= 0
        )
      )
      """
    )

    create(
      constraint(:operational_memory_entries, :operational_memory_edit_provenance_valid,
        check: """
        (edited_at IS NULL AND edited_by_actor_ref IS NULL AND edit_review_ref IS NULL) OR
        (edited_at IS NOT NULL AND char_length(edited_by_actor_ref) BETWEEN 1 AND 1024 AND
         char_length(edit_review_ref) BETWEEN 1 AND 256)
        """
      )
    )

    create(
      constraint(:operator_behaviors, :operator_behavior_edit_provenance_valid,
        check: """
        (edited_at IS NULL AND edited_by_actor_ref IS NULL AND edit_review_ref IS NULL) OR
        (edited_at IS NOT NULL AND char_length(edited_by_actor_ref) BETWEEN 1 AND 1024 AND
         char_length(edit_review_ref) BETWEEN 1 AND 256)
        """
      )
    )

    create table(:conversation_summary_drafts, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:episode_id, references(:episode_kernel_episodes, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(
        :turn_id,
        references(:episode_work_turns,
          type: :uuid,
          on_delete: :delete_all,
          with: [episode_id: :episode_id],
          name: :conversation_summary_draft_turn_episode_fkey
        ),
        null: false
      )

      add(:revision, :bigint, null: false, default: 1)
      add(:state, :text, null: false)
      add(:state_fingerprint, :text, null: false)
      add(:candidate_sha256, :text)
      add(:candidate_attempt, :bigint)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_summary_drafts, [:turn_id]))

    create(
      constraint(:conversation_summary_drafts, :conversation_summary_draft_valid,
        check:
          "revision > 0 AND octet_length(state) BETWEEN 2 AND 32768 AND char_length(state_fingerprint) = 64 AND " <>
            "((candidate_sha256 IS NULL AND candidate_attempt IS NULL) OR " <>
            "(char_length(candidate_sha256) = 64 AND candidate_attempt > 0))"
      )
    )

    create table(:conversation_summaries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:ref, :text, null: false)
      add(:identity_key, :text, null: false)
      add(:transport, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:thread_ref, :text)
      add(:repository_ref, :text)
      add(:visibility, :text, null: false)
      add(:state, :text, null: false)
      add(:state_fingerprint, :text, null: false)

      add(
        :source_episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :nilify_all)
      )

      add(
        :source_turn_id,
        references(:episode_work_turns,
          type: :uuid,
          on_delete: :nilify_all,
          with: [source_episode_id: :episode_id],
          name: :conversation_summary_source_turn_episode_fkey
        )
      )

      add(:source_result_ref, :text, null: false)
      add(:source_message_ref, :text)
      add(:recall_count, :bigint, null: false, default: 0)
      add(:last_recalled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_summaries, [:ref]))
    create(unique_index(:conversation_summaries, [:identity_key]))

    create(
      index(:conversation_summaries, [:workspace_ref, :visibility, :updated_at],
        name: :conversation_summaries_recall
      )
    )

    create(index(:conversation_summaries, [:repository_ref, :updated_at]))

    create(
      constraint(:conversation_summaries, :conversation_summary_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256 AND char_length(identity_key) = 64 AND
        char_length(transport) BETWEEN 1 AND 64 AND
        char_length(workspace_ref) BETWEEN 1 AND 1024 AND
        char_length(conversation_ref) BETWEEN 1 AND 1024 AND
        (thread_ref IS NULL OR char_length(thread_ref) BETWEEN 1 AND 1024) AND
        (repository_ref IS NULL OR char_length(repository_ref) BETWEEN 1 AND 1024) AND
        visibility IN ('public', 'private', 'direct', 'conversation') AND
        octet_length(state) BETWEEN 2 AND 32768 AND char_length(state_fingerprint) = 64 AND
        char_length(source_result_ref) BETWEEN 1 AND 1024 AND
        (source_message_ref IS NULL OR char_length(source_message_ref) BETWEEN 1 AND 1024) AND
        recall_count >= 0
        """
      )
    )

    create table(:conversation_rollups, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:ref, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:scope_ref, :text, null: false)
      add(:repository_ref, :text)
      add(:visibility, :text, null: false)
      add(:period_start, :utc_datetime_usec, null: false)
      add(:period_end, :utc_datetime_usec, null: false)
      add(:state, :text, null: false)
      add(:state_fingerprint, :text, null: false)
      add(:source_refs, :text, null: false)
      add(:source_scopes, :text, null: false)
      add(:source_count, :bigint, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:recall_count, :bigint, null: false, default: 0)
      add(:last_recalled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_rollups, [:ref]))

    create(
      unique_index(
        :conversation_rollups,
        [:workspace_ref, :scope_kind, :scope_ref, :period_start],
        name: :conversation_rollups_identity
      )
    )

    create(
      index(:conversation_rollups, [:workspace_ref, :scope_kind, :scope_ref, :period_end],
        name: :conversation_rollups_recall
      )
    )

    create(index(:conversation_rollups, [:expires_at]))

    create(
      constraint(:conversation_rollups, :conversation_rollup_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256 AND
        char_length(workspace_ref) BETWEEN 1 AND 1024 AND
        scope_kind IN ('conversation', 'repository') AND
        char_length(scope_ref) BETWEEN 1 AND 1024 AND
        (repository_ref IS NULL OR char_length(repository_ref) BETWEEN 1 AND 1024) AND
        visibility IN ('public', 'private', 'direct', 'conversation') AND
        period_end >= period_start AND expires_at > period_end AND
        octet_length(state) BETWEEN 2 AND 32768 AND char_length(state_fingerprint) = 64 AND
        octet_length(source_refs) BETWEEN 2 AND 32768 AND
        octet_length(source_scopes) BETWEEN 2 AND 8388608 AND
        source_count > 0 AND recall_count >= 0 AND
        ((scope_kind = 'repository' AND repository_ref = scope_ref AND visibility = 'public') OR
         (scope_kind = 'conversation'))
        """
      )
    )

    create table(:memory_review_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:ref, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:kind, :text, null: false)
      add(:entry_refs, :text, null: false)
      add(:reason, :text, null: false)
      add(:source_digest, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:action, :text)
      add(:reviewed_by_actor_ref, :text)
      add(:reviewed_at, :utc_datetime_usec)
      add(:replacement, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:memory_review_items, [:ref]))
    create(unique_index(:memory_review_items, [:source_digest]))
    create(index(:memory_review_items, [:workspace_ref, :status, :inserted_at]))

    create(
      constraint(:memory_review_items, :memory_review_item_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256 AND
        char_length(workspace_ref) BETWEEN 1 AND 1024 AND
        kind IN ('stale', 'duplicate') AND octet_length(entry_refs) BETWEEN 2 AND 32768 AND
        char_length(reason) BETWEEN 1 AND 2000 AND char_length(source_digest) = 64 AND
        status IN ('pending', 'kept', 'applied', 'dismissed') AND
        ((status = 'pending' AND action IS NULL AND reviewed_by_actor_ref IS NULL AND
          reviewed_at IS NULL AND replacement IS NULL) OR
         (status <> 'pending' AND action IN ('keep', 'merge', 'edit', 'forget', 'dismiss') AND
          char_length(reviewed_by_actor_ref) BETWEEN 1 AND 1024 AND reviewed_at IS NOT NULL AND
          (replacement IS NULL OR octet_length(replacement) BETWEEN 2 AND 32768)))
        """
      )
    )

    execute(
      "SELECT 1",
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM #{qualified("conversation_summary_drafts")} LIMIT 1) OR
           EXISTS (SELECT 1 FROM #{qualified("conversation_summaries")} LIMIT 1) OR
           EXISTS (SELECT 1 FROM #{qualified("conversation_rollups")} LIMIT 1) OR
           EXISTS (SELECT 1 FROM #{qualified("memory_review_items")} LIMIT 1) OR
           EXISTS (
             SELECT 1 FROM #{qualified("operational_memory_entries")}
             WHERE last_reviewed_at IS NOT NULL OR edited_at IS NOT NULL OR
                   edited_by_actor_ref IS NOT NULL OR edit_review_ref IS NOT NULL
             LIMIT 1
           ) OR
           EXISTS (
             SELECT 1 FROM #{qualified("operator_behaviors")}
             WHERE last_reviewed_at IS NOT NULL OR edited_at IS NOT NULL OR
                   edited_by_actor_ref IS NOT NULL OR edit_review_ref IS NOT NULL
             LIMIT 1
           ) OR
           EXISTS (
             SELECT 1 FROM #{qualified("slack_channel_memberships")}
             WHERE external_shared IS NOT NULL OR private IS NOT NULL
             LIMIT 1
           ) OR
           EXISTS (
             SELECT 1 FROM #{qualified("episode_work_turns")}
             WHERE final_preflight_continuity_sha256 IS NOT NULL
             LIMIT 1
           ) THEN
          RAISE EXCEPTION 'conversation continuity has data and cannot be rolled back safely';
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
