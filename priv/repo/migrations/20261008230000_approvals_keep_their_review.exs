defmodule Ryker.Repo.Migrations.ApprovalsKeepTheirReview do
  use Ecto.Migration

  # A reply that asked for several approvals shows them all, and an update of
  # one draws the others again from what was last seen of them. Each approval
  # kept only its review's digest, so the others could not be drawn
  # (2026-10-08).

  def change do
    alter table(:episode_emisar_approvals) do
      add(:review, :text)
    end

    create(
      constraint(:episode_emisar_approvals, :episode_emisar_approval_review_document_valid,
        check:
          "review IS NULL OR (octet_length(review) BETWEEN 2 AND 65536 " <>
            "AND jsonb_typeof(review::jsonb) = 'object')"
      )
    )
  end
end
