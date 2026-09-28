defmodule Ryker.Repo.Migrations.KeepRemovedRepositoryNames do
  use Ecto.Migration

  # Andrew, 2026-09-28: "repos must be named like on GH: andrewdryga/andrewdryga".
  # Removing a repository deleted its settings row, and with it the only
  # record of its GitHub name, while its requests, usage, learned topics and
  # knowledge keep its ref: every page then named it by the ref
  # ("andrewdryga-andrewdryga"). Ryker now keeps the name here when it removes
  # a repository (`Ryker.Settings.delete_repository/3`), so that history still
  # reads owner/repo (`Ryker.ControlPlane.RepositoryNames`).
  #
  # Rolling back drops the table; history then reads the ref again.

  def change do
    create table(:removed_repository_names, primary_key: false) do
      add(:ref, :text, primary_key: true)
      add(:name, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end
  end
end
