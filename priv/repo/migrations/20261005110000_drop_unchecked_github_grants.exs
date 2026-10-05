defmodule Ryker.Repo.Migrations.DropUncheckedGitHubGrants do
  use Ecto.Migration

  # A repository's "Allowed actions" listed opening pull requests, updating
  # Ryker's branch and issues, derived from the App's permissions, though no
  # tool ever checked them (2026-10-04 review). Coop's worker opens and
  # updates pull requests under the publication's own approval. The grants
  # nothing checks go, from every binding and from the column's default.
  def up do
    execute("""
    UPDATE github_binding_settings
    SET action_grants = array_remove(
      array_remove(array_remove(action_grants, 'open_pull_request'), 'update_ryker_branch'),
      'issues'
    )
    """)

    execute("""
    ALTER TABLE github_binding_settings
      ALTER COLUMN action_grants SET DEFAULT ARRAY['read', 'review', 'rerun_ci']::varchar[]
    """)
  end

  # Going back restores the old default; the derived grants come back with
  # the earlier code's next installation event.
  def down do
    execute("""
    ALTER TABLE github_binding_settings
      ALTER COLUMN action_grants
      SET DEFAULT ARRAY['read', 'review', 'open_pull_request', 'update_ryker_branch', 'rerun_ci']::varchar[]
    """)
  end
end
