defmodule Ryker.Repo.Migrations.DropRetiredCommitIdentity do
  use Ecto.Migration

  # Draft pull requests commit as the GitHub App since 2026-09-27
  # (844672138, controller-owned Coop jobs); the commit author name and email
  # settings it replaced stayed as columns nothing read or wrote (2026-10-08
  # rule pass; the local install held the defaults). The check that bounded
  # them also bounds the branch prefix, so it is made again for that alone.

  def up do
    drop(constraint(:publication_settings, :publication_settings_valid))

    alter table(:publication_settings) do
      remove(:commit_name)
      remove(:commit_email)
    end

    create(
      constraint(:publication_settings, :publication_settings_valid,
        check: "char_length(branch_prefix) >= 1 AND char_length(branch_prefix) <= 240"
      )
    )
  end

  def down do
    drop(constraint(:publication_settings, :publication_settings_valid))

    alter table(:publication_settings) do
      add(:commit_name, :text, null: false, default: "Ryker")
      add(:commit_email, :text, null: false, default: "ryker@localhost")
    end

    create(
      constraint(:publication_settings, :publication_settings_valid,
        check:
          "char_length(branch_prefix) >= 1 AND char_length(branch_prefix) <= 240 AND " <>
            "char_length(commit_name) >= 1 AND char_length(commit_name) <= 256 AND " <>
            "char_length(commit_email) >= 3 AND char_length(commit_email) <= 320"
      )
    )
  end
end
