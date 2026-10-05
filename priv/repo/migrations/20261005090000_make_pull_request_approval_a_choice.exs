defmodule Ryker.Repo.Migrations.MakePullRequestApprovalAChoice do
  use Ecto.Migration

  # Approving a pull request was granted to every repository whose App could
  # write pull requests, derived again on each installation event, and could
  # not be turned off; merging was granted the same way and no tool used it
  # (2026-10-04 review). Approval is now each repository's own choice, off
  # until someone makes it, and neither is derived from App permissions.
  def up do
    alter table(:github_binding_settings) do
      add(:approvals_allowed, :boolean, null: false, default: false)
    end

    execute("""
    UPDATE github_binding_settings
    SET action_grants = array_remove(array_remove(action_grants, 'approve'), 'merge')
    """)
  end

  # Going back restores no grant: the earlier code derives them again from
  # the App's permissions on its next installation event.
  def down do
    alter table(:github_binding_settings) do
      remove(:approvals_allowed)
    end
  end
end
