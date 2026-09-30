defmodule Ryker.Repo.Migrations.DropManualPullRequestChecks do
  use Ecto.Migration

  # "Check delivery" asked Ryker to look at an open pull request at once. It
  # already looks every ten minutes and at once on each check, workflow or pull
  # request event, and Andrew could not tell what the button did (2026-09-30),
  # so it is gone, and with it the marker a pending request left on the
  # follow-up.

  def up do
    alter table(:episode_publication_followups) do
      remove(:manual_check_ref)
    end
  end

  def down do
    alter table(:episode_publication_followups) do
      add(:manual_check_ref, :text)
    end
  end
end
