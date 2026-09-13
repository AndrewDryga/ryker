defmodule Ryker.Repo.Migrations.CreateConversationLearningRuns do
  use Ecto.Migration

  def up do
    create table(:conversation_learning_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:batch_key, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:status, :text, null: false)
      add(:inputs, :text, null: false)
      add(:source_dependencies, :text, null: false)
      add(:knowledge, :text, null: false)
      add(:omissions, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:prompt, :text)
      add(:prompt_sha256, :text, null: false)
      add(:output_schema, :text, null: false)
      add(:result, :text)
      add(:result_sha256, :text)
      add(:producer, :text, null: false, default: "{}")
      add(:error_code, :text)
      add(:applied_at, :utc_datetime_usec)
      add(:pruned_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_learning_runs, [:batch_key, :generation]))

    create(
      unique_index(:conversation_learning_runs, [:batch_key],
        where: "status = 'applied'",
        name: :conversation_learning_applied_once
      )
    )

    create(
      constraint(:conversation_learning_runs, :conversation_learning_status_valid,
        check:
          "status IN ('prepared', 'responded', 'applied', 'stale', 'rejected') AND generation > 0"
      )
    )
  end

  def down do
    # A completed historical learning pass cannot be erased by schema rollback.
    prefix = prefix() || "public"
    quoted = "\"" <> String.replace(prefix, "\"", "\"\"") <> "\""

    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{quoted}.conversation_learning_runs LIMIT 1) THEN RAISE EXCEPTION 'cannot remove retained learning history'; END IF; END $$"
    )

    drop(table(:conversation_learning_runs))
  end
end
