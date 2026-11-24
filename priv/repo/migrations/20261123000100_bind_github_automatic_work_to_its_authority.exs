defmodule Ryker.Repo.Migrations.BindGithubAutomaticWorkToItsAuthority do
  use Ecto.Migration

  def up do
    alter table(:github_indexed_issues) do
      add(:event_grant, :map)
    end

    # The original queue retained neither the actor nor the requested revision.
    # Retire pending reads without changing cached documents or saved plans.
    execute(
      "UPDATE github_indexed_issues SET pending = false, triage_pending = false WHERE pending"
    )

    alter table(:github_settings) do
      add(:trusted_installation_ids, {:array, :bigint}, null: false, default: [])
    end

    alter table(:github_repository_events) do
      add(:denial_thread, :text)
      add(:denial_reserved_at, :utc_datetime_usec)
    end

    create(
      index(:github_repository_events, [:binding_ref, :repository_id, :denial_reserved_at],
        where: "denial_reserved_at IS NOT NULL"
      )
    )
  end

  def down do
    raise "Restore the controller backup to undo GitHub writer authorization"
  end
end
