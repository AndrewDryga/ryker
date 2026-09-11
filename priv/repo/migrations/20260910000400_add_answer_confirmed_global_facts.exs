defmodule Responder.Repo.Migrations.AddAnswerConfirmedGlobalFacts do
  use Ecto.Migration

  def up do
    alter table(:operational_memory_entries) do
      add(:answer_provenance, :text)
      modify(:expires_at, :utc_datetime_usec, null: true)
    end

    drop(constraint(:operational_memory_entries, :operational_memory_provenance_valid))
    drop(constraint(:operational_memory_entries, :operational_memory_entry_valid))

    create(
      constraint(:operational_memory_entries, :operational_memory_provenance_valid,
        check: """
        (offer_record_id IS NOT NULL AND cutover_item_id IS NULL AND answer_provenance IS NULL) OR
        (offer_record_id IS NULL AND cutover_item_id IS NOT NULL AND answer_provenance IS NULL) OR
        (offer_record_id IS NULL AND cutover_item_id IS NULL AND answer_provenance IS NOT NULL AND
         octet_length(answer_provenance) BETWEEN 2 AND 8192 AND scope_kind = 'global')
        """
      )
    )

    create(
      constraint(:operational_memory_entries, :operational_memory_entry_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256 AND
        kind IN ('alias', 'repository_binding', 'evidence_route', 'entity_relationship') AND
        status IN ('active', 'superseded', 'deleted', 'expired') AND
        char_length(workspace_ref) BETWEEN 1 AND 1024 AND
        char_length(scope_ref) BETWEEN 1 AND 1024 AND
        char_length(subject) BETWEEN 1 AND 120 AND
        octet_length(payload) BETWEEN 2 AND 32768 AND
        char_length(payload_fingerprint) = 64 AND
        char_length(confirmed_by_actor_ref) BETWEEN 1 AND 1024 AND
        char_length(confirmation_ref) BETWEEN 1 AND 1024 AND
        char_length(source_transport) BETWEEN 1 AND 1024 AND
        char_length(source_conversation_ref) BETWEEN 1 AND 1024 AND
        (source_thread_ref IS NULL OR char_length(source_thread_ref) BETWEEN 1 AND 1024) AND
        char_length(source_message_ref) BETWEEN 1 AND 1024 AND recall_count >= 0 AND
        (
          (scope_kind = 'global' AND visibility = 'global' AND workspace_ref = 'installation' AND
           scope_ref ~ '^installation:[a-f0-9]{64}$' AND expires_at IS NULL AND answer_provenance IS NOT NULL)
          OR
          (scope_kind IN ('conversation', 'repository', 'workspace') AND
           visibility IN ('conversation', 'workspace') AND expires_at IS NOT NULL AND
           expires_at > confirmed_at AND answer_provenance IS NULL AND
           ((scope_kind = 'conversation' AND visibility = 'conversation') OR
            scope_kind = 'repository' OR (scope_kind = 'workspace' AND visibility = 'workspace')))
        )
        """
      )
    )

    create(
      unique_index(:operational_memory_entries, [:confirmation_ref],
        name: :operational_memory_answer_confirmation,
        where: "answer_provenance IS NOT NULL"
      )
    )
  end

  def down do
    raise "global answer confirmations cannot be removed without losing user history"
  end
end
