defmodule Ryker.Repo.Migrations.AddGitHubIssueWorkflows do
  use Ecto.Migration

  def up do
    alter table(:repository_settings) do
      add(:github_issue_actions, :boolean, null: false, default: false)
    end

    create table(:github_issue_workflows, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:identity, :text, null: false)
      add(:binding_ref, :text, null: false)
      add(:repository_ref, :text, null: false)
      add(:repository_id, :bigint, null: false)
      add(:installation_id, :bigint, null: false)
      add(:number, :bigint, null: false)
      add(:revision, :integer, null: false, default: 0)
      add(:current_plan_id, :uuid)
      add(:current_request_id, :uuid)
      add(:issue_snapshot, :text, null: false)
      add(:external_receipt, :text)
      add(:rendered_fingerprint, :text)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:github_issue_workflows, [:identity]))

    create(
      index(:github_issue_workflows, [:next_attempt_at], where: "next_attempt_at IS NOT NULL")
    )

    create(
      constraint(:github_issue_workflows, :github_issue_workflow_valid,
        check: """
        identity ~ '^[0-9a-f]{64}$' AND repository_id > 0 AND installation_id > 0 AND number > 0
        AND revision >= 0 AND attempt_count >= 0
        AND ((lease_ref IS NULL) = (lease_expires_at IS NULL))
        AND octet_length(issue_snapshot) <= 65536 AND jsonb_typeof(issue_snapshot::jsonb) = 'object'
        AND (rendered_fingerprint IS NULL OR rendered_fingerprint ~ '^[0-9a-f]{64}$')
        """
      )
    )

    create table(:github_issue_plans, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workflow_id, references(:github_issue_workflows, type: :uuid), null: false)
      add(:revision, :integer, null: false)
      add(:parent_plan_id, :uuid)
      add(:source_key, :text, null: false)
      add(:body, :text, null: false)
      add(:source_commit, :text, null: false)
      add(:issue_snapshot, :text, null: false)
      add(:author_ref, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:github_issue_plans, [:workflow_id, :id]))
    create(unique_index(:github_issue_plans, [:workflow_id, :revision]))
    create(unique_index(:github_issue_plans, [:workflow_id, :source_key]))

    create(
      constraint(:github_issue_plans, :github_issue_plan_valid,
        check: """
        revision > 0 AND octet_length(body) BETWEEN 1 AND 16000 AND length(btrim(body)) > 0
        AND source_commit ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
        AND octet_length(issue_snapshot) <= 65536 AND jsonb_typeof(issue_snapshot::jsonb) = 'object'
        AND octet_length(author_ref) BETWEEN 1 AND 256 AND octet_length(source_key) BETWEEN 1 AND 256
        """
      )
    )

    create table(:github_issue_requests, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workflow_id, references(:github_issue_workflows, type: :uuid), null: false)
      add(:plan_id, :uuid)
      add(:kind, :text, null: false)
      add(:request_key, :text, null: false)
      add(:base_revision, :integer, null: false)
      add(:source_snapshot, :text, null: false)
      add(:actor_id, :bigint, null: false)

      # The copied source remains after ingress retention; this is a historical ID, not a foreign key.
      add(:entry_id, :uuid, null: false)
      add(:outcome, :text)
      add(:finished_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:github_issue_requests, [:workflow_id, :id]))
    create(unique_index(:github_issue_requests, [:workflow_id, :request_key]))
    create(unique_index(:github_issue_requests, [:entry_id]))

    create(
      constraint(:github_issue_requests, :github_issue_request_valid,
        check: """
        kind IN ('make_plan','build_issue','implement_plan') AND base_revision >= 0 AND actor_id > 0
        AND ((kind = 'implement_plan') = (plan_id IS NOT NULL))
        AND request_key ~ '^[0-9a-f]{64}$'
        AND octet_length(source_snapshot) <= 65536 AND jsonb_typeof(source_snapshot::jsonb) = 'object'
        """
      )
    )

    create(
      constraint(:github_issue_requests, :github_issue_request_outcome_valid,
        check: """
        (outcome IS NULL AND finished_at IS NULL) OR
        (outcome IS NOT NULL AND finished_at IS NOT NULL AND octet_length(outcome) <= 16384
          AND jsonb_typeof(outcome::jsonb) = 'object')
        """
      )
    )

    execute(
      "ALTER TABLE github_issue_plans ADD CONSTRAINT github_issue_plan_parent_owned FOREIGN KEY (workflow_id, parent_plan_id) REFERENCES github_issue_plans(workflow_id, id)"
    )

    execute(
      "ALTER TABLE github_issue_requests ADD CONSTRAINT github_issue_request_plan_owned FOREIGN KEY (workflow_id, plan_id) REFERENCES github_issue_plans(workflow_id, id)"
    )

    execute(
      "ALTER TABLE github_issue_workflows ADD CONSTRAINT github_issue_workflow_plan_owned FOREIGN KEY (id, current_plan_id) REFERENCES github_issue_plans(workflow_id, id)"
    )

    execute(
      "ALTER TABLE github_issue_workflows ADD CONSTRAINT github_issue_workflow_request_owned FOREIGN KEY (id, current_request_id) REFERENCES github_issue_requests(workflow_id, id)"
    )
  end

  def down do
    raise "Restore a controller backup to remove issue workflows without deleting plan history."
  end
end
