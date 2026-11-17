defmodule Ryker.Repo.Migrations.ReturnTaskPublicationResultsToWork do
  use Ecto.Migration

  # Automatic tasks resume Work with publication evidence instead of inventing
  # an external delivery receipt for a canned notification. Existing receipts
  # remain historical evidence; review and publication proofs are still required.
  def up, do: replace_constraints(true)
  def down, do: replace_constraints(false)

  defp replace_constraints(task_outcomes?) do
    task_review =
      if task_outcomes?,
        do:
          "OR (review_request_ref LIKE 'task-readiness:%' AND status IN ('reviewed', 'publish_pending', 'published_ready', 'published', 'blocked', 'discarded'))",
        else: ""

    task_publish =
      if task_outcomes?,
        do:
          "OR (review_request_ref LIKE 'task-readiness:%' AND status IN ('published', 'discarded'))",
        else: ""

    execute("ALTER TABLE episode_publications DROP CONSTRAINT episode_publication_review_valid")
    execute("ALTER TABLE episode_publications DROP CONSTRAINT episode_publication_publish_valid")

    execute("""
    ALTER TABLE episode_publications ADD CONSTRAINT episode_publication_review_valid CHECK (
      (review_document IS NULL AND review_fingerprint IS NULL AND review_patch IS NULL
        AND reviewed_at IS NULL AND review_delivery_receipt IS NULL
        AND review_delivery_receipt_fingerprint IS NULL AND status IN ('review_pending', 'discarded'))
      OR (review_document IS NOT NULL AND char_length(review_fingerprint) = 64 AND reviewed_at IS NOT NULL
        AND ((review_delivery_receipt IS NULL AND review_delivery_receipt_fingerprint IS NULL
          AND (status = 'review_ready' #{task_review}))
        OR (review_delivery_receipt IS NOT NULL AND char_length(review_delivery_receipt_fingerprint) = 64
          AND status IN ('reviewed', 'publish_pending', 'published_ready', 'published', 'blocked', 'discarded')))))
    """)

    execute("""
    ALTER TABLE episode_publications ADD CONSTRAINT episode_publication_publish_valid CHECK (
      (publication_receipt IS NULL AND publication_receipt_fingerprint IS NULL AND published_at IS NULL
        AND published_delivery_receipt IS NULL AND published_delivery_receipt_fingerprint IS NULL
        AND status NOT IN ('published_ready', 'published'))
      OR (publication_receipt IS NOT NULL AND char_length(publication_receipt_fingerprint) = 64
        AND published_at IS NOT NULL
        AND ((published_delivery_receipt IS NULL AND published_delivery_receipt_fingerprint IS NULL
          AND (status = 'published_ready' #{task_publish}))
        OR (published_delivery_receipt IS NOT NULL AND char_length(published_delivery_receipt_fingerprint) = 64
          AND status IN ('published', 'discarded')))))
    """)
  end
end
