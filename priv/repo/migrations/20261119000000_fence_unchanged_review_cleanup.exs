defmodule Ryker.Repo.Migrations.FenceUnchangedReviewCleanup do
  use Ecto.Migration

  def up do
    alter table(:episode_work_sessions) do
      add(:discard_plan_unchanged_head, :text)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_unchanged_head_valid,
        check: """
        discard_plan_unchanged_head IS NULL OR (
          discard_plan_unchanged_head ~ '^([0-9a-f]{40}|[0-9a-f]{64})$' AND
          discard_plan_accept_unmerged AND NOT discard_plan_accept_dirty
        )
        """
      )
    )
  end

  def down do
    raise "Restore the controller backup to preserve cleanup authorization"
  end
end
