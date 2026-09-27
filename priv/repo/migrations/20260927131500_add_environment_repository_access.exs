defmodule Ryker.Repo.Migrations.AddEnvironmentRepositoryAccess do
  use Ecto.Migration

  # Andrew, 2026-09-27, of an environment's repositories: "can we here limit
  # read or read/write access per repo?" Each repository of an environment is
  # now read only or read and write. Until now a task could change any
  # repository of its environment, so every repository already in one becomes
  # read and write, and work there keeps doing what it did. The default
  # (position 0) is the repository a task changes unless it picks another, so
  # it is always read and write. Every later write names the access, so the
  # column keeps no default.
  def up do
    alter table(:environment_repository_settings) do
      add(:access, :text, null: false, default: "read_write")
    end

    alter table(:environment_repository_settings) do
      modify(:access, :text, null: false, default: nil)
    end

    create(
      constraint(:environment_repository_settings, :environment_repository_settings_access_valid,
        check: "access IN ('read_only', 'read_write') AND (position > 0 OR access = 'read_write')"
      )
    )
  end

  def down do
    drop(
      constraint(:environment_repository_settings, :environment_repository_settings_access_valid)
    )

    alter table(:environment_repository_settings) do
      remove(:access)
    end
  end
end
