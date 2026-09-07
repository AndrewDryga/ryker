defmodule Responder.Repo.Migrations.RetainWorkCandidateResponses do
  use Ecto.Migration

  def up do
    create table(:work_candidate_responses, primary_key: false) do
      add(
        :turn_id,
        references(:episode_work_turns, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:candidate_attempt, :bigint, primary_key: true)
      add(:body, :text)
      add(:sha256, :text, null: false)
      add(:byte_size, :integer, null: false)
      add(:recorded_at, :utc_datetime_usec, null: false)
      add(:operational_pruned_at, :utc_datetime_usec)
    end

    create(
      constraint(:work_candidate_responses, :work_candidate_response_identity_valid,
        check:
          "candidate_attempt > 0 AND sha256 ~ '^[0-9a-f]{64}$' AND byte_size BETWEEN 1 AND 262144"
      )
    )

    create(
      constraint(:work_candidate_responses, :work_candidate_response_retention_valid,
        check: """
        (operational_pruned_at IS NULL AND body IS NOT NULL AND octet_length(body) = byte_size)
        OR (operational_pruned_at IS NOT NULL AND body IS NULL)
        """
      )
    )
  end

  def down do
    schema = ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")

    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{schema}.work_candidate_responses LIMIT 1) THEN RAISE EXCEPTION 'export candidate response history before rollback'; END IF; END $$"
    )

    drop(table(:work_candidate_responses))
  end
end
