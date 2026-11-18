defmodule Ryker.Repo.Migrations.AddGitHubCIRepairCustody do
  use Ecto.Migration

  def up do
    create table(:github_ci_repairs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:identity, :text, null: false)
      add(:binding_ref, :text, null: false)
      add(:repository_ref, :text, null: false)
      add(:repository_id, :bigint, null: false)
      add(:installation_id, :bigint, null: false)
      add(:number, :bigint, null: false)
      add(:revision, :integer, null: false, default: 0)
      add(:generation, :integer, null: false, default: 1)
      add(:rounds, :integer, null: false, default: 0)
      add(:failure_open, :boolean, null: false, default: false)
      add(:pending_heads, {:array, :text}, null: false, default: [])
      add(:refresh_requested, :boolean, null: false, default: false)
      add(:current_round_id, :uuid)
      add(:allowed, :boolean, null: false, default: false)
      add(:last_attempt_head, :text)
      add(:status, :text, null: false, default: "pending")
      add(:observation, :text)
      add(:external_receipt, :text)
      add(:rendered_fingerprint, :text)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:attempt_count, :integer, null: false, default: 0)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:github_ci_repairs, [:identity]))
    create(index(:github_ci_repairs, [:next_attempt_at], where: "next_attempt_at IS NOT NULL"))

    create(
      constraint(:github_ci_repairs, :github_ci_repair_valid,
        check: """
        identity ~ '^[0-9a-f]{64}$' AND repository_id > 0 AND installation_id > 0 AND number > 0
        AND revision >= 0 AND generation > 0 AND rounds BETWEEN 0 AND 2 AND attempt_count >= 0
        AND cardinality(pending_heads) <= 20
        AND ((lease_ref IS NULL) = (lease_expires_at IS NULL))
        AND (observation IS NULL OR (octet_length(observation) <= 65536 AND jsonb_typeof(observation::jsonb) = 'object'))
        """
      )
    )

    create table(:github_ci_repair_rounds, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:repair_id, references(:github_ci_repairs, type: :uuid), null: false)
      add(:generation, :integer, null: false)
      add(:ordinal, :integer, null: false)
      # Historical ingress identity survives source retention.
      add(:entry_id, :uuid, null: false)
      add(:head, :text, null: false)
      add(:snapshot, :text, null: false)
      add(:outcome, :text)
      add(:finished_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:github_ci_repair_rounds, [:repair_id, :id]))
    create(unique_index(:github_ci_repair_rounds, [:repair_id, :generation, :ordinal]))
    create(unique_index(:github_ci_repair_rounds, [:entry_id]))

    create(
      constraint(:github_ci_repair_rounds, :github_ci_repair_round_valid,
        check: """
        generation > 0 AND ordinal BETWEEN 1 AND 2 AND head ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
        AND octet_length(snapshot) <= 65536 AND jsonb_typeof(snapshot::jsonb) = 'object'
        AND ((outcome IS NULL) = (finished_at IS NULL))
        """
      )
    )

    execute("""
    ALTER TABLE github_ci_repairs ADD CONSTRAINT github_ci_repair_round_owned
    FOREIGN KEY (id, current_round_id) REFERENCES github_ci_repair_rounds(repair_id, id)
    """)
  end

  def down do
    raise "Restore the controller backup to undo CI repair custody without deleting history"
  end
end
