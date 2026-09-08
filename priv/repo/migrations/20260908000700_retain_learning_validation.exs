defmodule Responder.Repo.Migrations.RetainLearningValidation do
  use Ecto.Migration

  def change do
    alter table(:conversation_learning_runs) do
      add(:submit_revision, :bigint)
      add(:coop_turn_id, :text)
      add(:candidate_attempt, :integer)
      add(:validation_receipt, :text)
      add(:stop_receipt, :text)
      add(:remote_stopped_at, :utc_datetime_usec)
      add(:reconcile_attempt_count, :integer, null: false, default: 0)
    end

    create(
      constraint(:conversation_learning_runs, :learning_remote_stop_proven,
        check: "(remote_stopped_at IS NULL) = (stop_receipt IS NULL)"
      )
    )

    create(
      constraint(:conversation_learning_runs, :learning_reconcile_count_valid,
        check: "reconcile_attempt_count >= 0"
      )
    )
  end
end
