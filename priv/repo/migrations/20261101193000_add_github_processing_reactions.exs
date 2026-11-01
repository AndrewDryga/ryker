defmodule Ryker.Repo.Migrations.AddGitHubProcessingReactions do
  use Ecto.Migration

  def change do
    create table(:github_processing_reactions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:binding, :text, null: false)
      add(:repository_id, :bigint, null: false)
      add(:actor_id, :bigint, null: false)
      add(:comment_kind, :text, null: false)
      add(:comment_id, :bigint, null: false)
      add(:desired, :boolean, null: false, default: true)
      add(:reaction_id, :bigint)
      add(:uncertain, :boolean, null: false, default: false)
      add(:blocked, :boolean, null: false, default: false)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:last_error_detail, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :github_processing_reactions,
        [:binding, :repository_id, :actor_id, :comment_kind, :comment_id],
        name: :github_processing_reaction_identity_unique
      )
    )

    create(
      constraint(:github_processing_reactions, :github_processing_reaction_valid,
        check:
          "repository_id > 0 AND actor_id > 0 AND comment_id > 0 AND (reaction_id IS NULL OR reaction_id > 0) AND comment_kind IN ('issue_comment', 'pull_request_review_comment') AND attempt_count >= 0 AND ((lease_ref IS NULL) = (lease_expires_at IS NULL))"
      )
    )
  end
end
