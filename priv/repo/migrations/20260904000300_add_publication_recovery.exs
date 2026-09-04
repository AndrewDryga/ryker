defmodule Responder.Repo.Migrations.AddPublicationRecovery do
  use Ecto.Migration

  def up do
    alter table(:episode_publications) do
      add(:recovery_generation, :bigint, null: false, default: 1)
    end

    drop(constraint(:episode_publications, :episode_publication_identity_valid))
    drop(constraint(:episode_publications, :episode_publication_review_valid))
    drop(constraint(:episode_publications, :episode_publication_approval_valid))

    create(
      constraint(:episode_publications, :episode_publication_identity_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256 AND
        char_length(repository) BETWEEN 1 AND 256 AND
        char_length(title) BETWEEN 1 AND 120 AND
        octet_length(body) BETWEEN 1 AND 8000 AND
        char_length(destination_transport) BETWEEN 1 AND 64 AND
        char_length(destination_conversation_ref) BETWEEN 1 AND 1024 AND
        (destination_thread_ref IS NULL OR char_length(destination_thread_ref) BETWEEN 1 AND 1024) AND
        char_length(offer_message_ref) BETWEEN 1 AND 1024 AND
        char_length(review_request_ref) BETWEEN 1 AND 1024 AND
        char_length(review_requested_by_actor_ref) BETWEEN 1 AND 1024 AND
        review_generation > 0 AND recovery_generation > 0 AND attempt_count >= 0 AND
        (review_expected_revision IS NULL OR review_expected_revision > 0)
        """
      )
    )

    create(
      constraint(:episode_publications, :episode_publication_review_valid,
        check: """
        (
          review_document IS NULL AND review_fingerprint IS NULL AND review_patch IS NULL AND
          reviewed_at IS NULL AND review_delivery_receipt IS NULL AND
          review_delivery_receipt_fingerprint IS NULL AND status IN ('review_pending', 'discarded')
        ) OR (
          review_document IS NOT NULL AND char_length(review_fingerprint) = 64 AND reviewed_at IS NOT NULL AND
          (
            (
              review_delivery_receipt IS NULL AND review_delivery_receipt_fingerprint IS NULL AND
              status = 'review_ready'
            ) OR (
              review_delivery_receipt IS NOT NULL AND char_length(review_delivery_receipt_fingerprint) = 64 AND
              status IN ('reviewed', 'publish_pending', 'published_ready', 'published', 'blocked', 'discarded')
            )
          )
        )
        """
      )
    )

    create(
      constraint(:episode_publications, :episode_publication_approval_valid,
        check: """
        (
          approval_ref IS NULL AND approved_by_actor_ref IS NULL AND approved_at IS NULL AND
          status IN ('review_pending', 'review_ready', 'reviewed', 'blocked', 'discarded')
        ) OR (
          char_length(approval_ref) BETWEEN 1 AND 1024 AND
          char_length(approved_by_actor_ref) BETWEEN 1 AND 1024 AND approved_at IS NOT NULL AND
          status IN ('publish_pending', 'published_ready', 'published')
        )
        """
      )
    )

    drop(constraint(:responder_operator_actions, :responder_operator_action_valid))

    create(
      constraint(:responder_operator_actions, :responder_operator_action_valid,
        check: """
        char_length(action_ref) BETWEEN 1 AND 1024 AND
        char_length(request_fingerprint) = 64 AND
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        action IN ('retry', 'replay', 'update', 'discard') AND
        char_length(kind) BETWEEN 1 AND 64 AND
        char_length(resource_ref) BETWEEN 1 AND 1024 AND
        jsonb_typeof(previous::jsonb) = 'object' AND
        jsonb_typeof(outcome::jsonb) = 'object'
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified_publications()} WHERE status = 'discarded' LIMIT 1) OR
         EXISTS (
           SELECT 1 FROM #{qualified_operator_actions()}
           WHERE action IN ('update', 'discard')
           LIMIT 1
         ) THEN
        RAISE EXCEPTION 'publication recovery has data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:responder_operator_actions, :responder_operator_action_valid))

    create(
      constraint(:responder_operator_actions, :responder_operator_action_valid,
        check: """
        char_length(action_ref) BETWEEN 1 AND 1024 AND
        char_length(request_fingerprint) = 64 AND
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        action IN ('retry', 'replay') AND
        char_length(kind) BETWEEN 1 AND 64 AND
        char_length(resource_ref) BETWEEN 1 AND 1024 AND
        jsonb_typeof(previous::jsonb) = 'object' AND
        jsonb_typeof(outcome::jsonb) = 'object'
        """
      )
    )

    drop(constraint(:episode_publications, :episode_publication_approval_valid))
    drop(constraint(:episode_publications, :episode_publication_review_valid))
    drop(constraint(:episode_publications, :episode_publication_identity_valid))

    alter table(:episode_publications) do
      remove(:recovery_generation)
    end

    create(
      constraint(:episode_publications, :episode_publication_identity_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 256 AND
        char_length(repository) BETWEEN 1 AND 256 AND
        char_length(title) BETWEEN 1 AND 120 AND
        octet_length(body) BETWEEN 1 AND 8000 AND
        char_length(destination_transport) BETWEEN 1 AND 64 AND
        char_length(destination_conversation_ref) BETWEEN 1 AND 1024 AND
        (destination_thread_ref IS NULL OR char_length(destination_thread_ref) BETWEEN 1 AND 1024) AND
        char_length(offer_message_ref) BETWEEN 1 AND 1024 AND
        char_length(review_request_ref) BETWEEN 1 AND 1024 AND
        char_length(review_requested_by_actor_ref) BETWEEN 1 AND 1024 AND
        review_generation > 0 AND attempt_count >= 0 AND
        (review_expected_revision IS NULL OR review_expected_revision > 0)
        """
      )
    )

    create(
      constraint(:episode_publications, :episode_publication_review_valid,
        check: """
        (
          review_document IS NULL AND review_fingerprint IS NULL AND review_patch IS NULL AND
          reviewed_at IS NULL AND review_delivery_receipt IS NULL AND
          review_delivery_receipt_fingerprint IS NULL AND status = 'review_pending'
        ) OR (
          review_document IS NOT NULL AND char_length(review_fingerprint) = 64 AND reviewed_at IS NOT NULL AND
          (
            (
              review_delivery_receipt IS NULL AND review_delivery_receipt_fingerprint IS NULL AND
              status = 'review_ready'
            ) OR (
              review_delivery_receipt IS NOT NULL AND char_length(review_delivery_receipt_fingerprint) = 64 AND
              status IN ('reviewed', 'publish_pending', 'published_ready', 'published', 'blocked')
            )
          )
        )
        """
      )
    )

    create(
      constraint(:episode_publications, :episode_publication_approval_valid,
        check: """
        (
          approval_ref IS NULL AND approved_by_actor_ref IS NULL AND approved_at IS NULL AND
          status IN ('review_pending', 'review_ready', 'reviewed', 'blocked')
        ) OR (
          char_length(approval_ref) BETWEEN 1 AND 1024 AND
          char_length(approved_by_actor_ref) BETWEEN 1 AND 1024 AND approved_at IS NOT NULL AND
          status IN ('publish_pending', 'published_ready', 'published')
        )
        """
      )
    )
  end

  defp qualified_publications, do: qualified("episode_publications")
  defp qualified_operator_actions, do: qualified("responder_operator_actions")

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
