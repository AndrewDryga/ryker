defmodule Responder.Repo.Migrations.AddPublicationStaleHeadRecovery do
  use Ecto.Migration

  def up do
    alter table(:episode_publications) do
      add(:expected_remote_head_sha, :text)
    end

    drop(constraint(:episode_publications, :episode_publication_approval_valid))
    drop(constraint(:episode_publications, :episode_publication_publish_valid))
    drop(constraint(:episode_publications, :episode_publication_remote_identity_valid))

    create(approval_constraint(true))
    create(publish_constraint(true))
    create(remote_identity_constraint(true))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified_publications()}
        WHERE expected_remote_head_sha IS NOT NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'publication stale-head recovery has data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_publications, :episode_publication_remote_identity_valid))
    drop(constraint(:episode_publications, :episode_publication_publish_valid))
    drop(constraint(:episode_publications, :episode_publication_approval_valid))

    alter table(:episode_publications) do
      remove(:expected_remote_head_sha)
    end

    create(approval_constraint(false))
    create(publish_constraint(false))
    create(remote_identity_constraint(false))
  end

  defp approval_constraint(discard_approved?) do
    approved_statuses =
      if discard_approved?,
        do: "'publish_pending', 'published_ready', 'published', 'discarded'",
        else: "'publish_pending', 'published_ready', 'published'"

    constraint(:episode_publications, :episode_publication_approval_valid,
      check: """
      (
        approval_ref IS NULL AND approved_by_actor_ref IS NULL AND approved_at IS NULL AND
        status IN ('review_pending', 'review_ready', 'reviewed', 'blocked', 'discarded')
      ) OR (
        char_length(approval_ref) BETWEEN 1 AND 1024 AND
        char_length(approved_by_actor_ref) BETWEEN 1 AND 1024 AND approved_at IS NOT NULL AND
        status IN (#{approved_statuses})
      )
      """
    )
  end

  defp publish_constraint(discard_published?) do
    delivered_statuses =
      if discard_published?, do: "'published', 'discarded'", else: "'published'"

    constraint(:episode_publications, :episode_publication_publish_valid,
      check: """
      (
        publication_receipt IS NULL AND publication_receipt_fingerprint IS NULL AND
        published_at IS NULL AND published_delivery_receipt IS NULL AND
        published_delivery_receipt_fingerprint IS NULL AND
        status NOT IN ('published_ready', 'published')
      ) OR (
        publication_receipt IS NOT NULL AND char_length(publication_receipt_fingerprint) = 64 AND
        published_at IS NOT NULL AND
        (
          (
            published_delivery_receipt IS NULL AND published_delivery_receipt_fingerprint IS NULL AND
            status = 'published_ready'
          ) OR (
            published_delivery_receipt IS NOT NULL AND
            char_length(published_delivery_receipt_fingerprint) = 64 AND
            status IN (#{delivered_statuses})
          )
        )
      )
      """
    )
  end

  defp remote_identity_constraint(with_expected_head?) do
    absent_expected =
      if with_expected_head?, do: " AND expected_remote_head_sha IS NULL", else: ""

    valid_expected =
      if with_expected_head?,
        do:
          " AND (expected_remote_head_sha IS NULL OR expected_remote_head_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$')",
        else: ""

    constraint(:episode_publications, :episode_publication_remote_identity_valid,
      check: """
      (
        github_repository IS NULL AND branch_ref IS NULL AND commit_sha IS NULL AND
        pull_request_number IS NULL AND pull_request_url IS NULL#{absent_expected}
      ) OR (
        github_repository ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' AND
        branch_ref ~ '^refs/heads/[A-Za-z0-9._/-]{1,240}$' AND
        commit_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$' AND pull_request_number > 0 AND
        octet_length(pull_request_url) BETWEEN 1 AND 2048#{valid_expected}
      )
      """
    )
  end

  defp qualified_publications do
    case prefix() do
      nil -> "episode_publications"
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".episode_publications)
    end
  end
end
