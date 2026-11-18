defmodule Ryker.Repo.Migrations.AddGitHubIssueTriage do
  use Ecto.Migration

  def up do
    alter table(:repository_settings) do
      add(:github_issue_triage, :boolean, null: false, default: false)
      add(:github_triage_labels, :boolean, null: false, default: false)
    end

    drop(constraint(:github_issue_requests, :github_issue_request_valid))

    create(
      constraint(:github_issue_requests, :github_issue_request_valid,
        check:
          "kind IN ('make_plan', 'build_issue', 'implement_plan', 'triage_issue') AND base_revision >= 0 AND ((kind = 'triage_issue' AND actor_id = 0) OR actor_id > 0) AND ((kind = 'implement_plan') = (plan_id IS NOT NULL)) AND request_key ~ '^[0-9a-f]{64}$' AND octet_length(source_snapshot) <= 65536 AND jsonb_typeof(source_snapshot::jsonb) = 'object'"
      )
    )
  end

  def down do
    raise "Restore the controller backup to undo triage without discarding saved requests"
  end
end
