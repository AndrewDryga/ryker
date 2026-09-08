defmodule Responder.Repo.Migrations.CreateLearningBatches do
  use Ecto.Migration

  def change do
    create table(:conversation_learning_batches, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scope_key, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:repository_ref, :text)
      add(:execution_mode, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:status, :text, null: false, default: "queued")
      add(:start_count, :integer, null: false, default: 0)
      add(:start_limit, :integer, null: false, default: 3)
      add(:budget_version, :integer, null: false, default: 0)
      add(:input_count, :integer, null: false)
      add(:lease_ref, :uuid)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:heartbeat_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:error_code, :text)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:conversation_learning_batches, [:status, :next_attempt_at, :inserted_at]))
    create(index(:conversation_learning_batches, [:scope_key, :inserted_at]))

    create(
      unique_index(:conversation_learning_batches, [:scope_key],
        where: "status IN ('queued', 'running')",
        name: :learning_one_active_scope
      )
    )

    create(
      constraint(:conversation_learning_batches, :learning_batch_state_valid,
        check:
          "status IN ('queued','running','applied','no_change','deferred','superseded') " <>
            "AND execution_mode IN ('live','shadow') AND budget_version >= 0 AND start_limit >= 1 AND start_count BETWEEN 0 AND start_limit " <>
            "AND input_count BETWEEN 1 AND 16 AND " <>
            "((status = 'running' AND lease_ref IS NOT NULL AND lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL) " <>
            "OR (status <> 'running' AND lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL))"
      )
    )

    create table(:conversation_learning_inputs, primary_key: false) do
      add(:input_id, references(:ingress_inbox_entries, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(
        :batch_id,
        references(:conversation_learning_batches, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:terminal_reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:conversation_learning_inputs, [:batch_id, :input_id]))

    alter table(:conversation_learning_runs) do
      add(:batch_id, references(:conversation_learning_batches, type: :uuid))
      add(:started_at, :utc_datetime_usec)
    end

    create(index(:conversation_learning_runs, [:batch_id, :generation]))

    create(
      index(:ingress_inbox_entries, [:inserted_at, :id],
        where: "status IN ('decided', 'superseded')",
        name: :learning_pending_input_order
      )
    )
  end
end
