defmodule Ryker.Repo.Migrations.KeepWorkExamples do
  use Ecto.Migration

  # Andrew, 2026-10-02: the self-hosted model should be "trained not just from routing records
  # but actual work records too". Everything a Work turn produced was pruned 30 days after its
  # request finished, and only routing decisions were copied for training.
  #
  # A work example is a redacted copy of one settled Work turn: the briefing the worker was
  # given, what it did on the way (its tool calls and progress notes, as recorded), the result
  # Ryker accepted and each one it refused with why, what happened next and what it cost. It is
  # kept under its own window while a person keeps "Keep work examples for training" on
  # (Settings > Data retention), a setting of its own beside the routing one: a work example
  # carries a customer's code and command output, which a routing example never does. It names
  # the rows it was copied from without a foreign key, because the copy outlives them, and one a
  # person forgot keeps only its identity, so it is never copied again.
  #
  # Rolling back refuses while any example is kept: the previous release has nowhere to keep
  # one, and dropping them would lose what was kept on purpose.

  def up do
    alter table(:retention_settings) do
      add(:work_examples_enabled, :boolean, null: false, default: false)
      add(:work_examples_seconds, :bigint, null: false, default: 365 * 86_400)
    end

    create(
      constraint(:retention_settings, :retention_settings_work_examples_valid,
        check: "work_examples_seconds BETWEEN 60 AND 315360000"
      )
    )

    create table(:work_examples, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:turn_id, :uuid, null: false)
      add(:episode_id, :uuid, null: false)
      add(:episode_ref, :text, null: false)
      add(:source_identities, {:array, :text}, null: false, default: [])
      add(:message_keys, {:array, :text}, null: false, default: [])
      add(:conversation_refs, {:array, :text}, null: false, default: [])
      add(:transport, :text)
      add(:conversation_ref, :text)
      add(:thread_ref, :text)
      add(:repository_ref, :text)
      add(:execution_mode, :text, null: false)
      add(:execution_target, :text)
      add(:briefing, :text)
      add(:context, :text)
      add(:output_schema, :text)
      add(:trajectory, :text)
      add(:result, :text)
      add(:rejected_results, :text)
      add(:outcome, :text)
      add(:usage, :text)
      add(:settled_at, :utc_datetime_usec, null: false)
      add(:forgotten_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:work_examples, [:turn_id]))
    create(index(:work_examples, [:settled_at, :id]))
    create(index(:work_examples, [:episode_id]))
    create(index(:work_examples, [:source_identities], using: :gin))
    create(index(:work_examples, [:message_keys], using: :gin))
    create(index(:work_examples, [:conversation_refs], using: :gin))

    create(
      constraint(:work_examples, :work_example_identity_valid,
        check: """
        execution_mode IN ('live', 'shadow')
        AND char_length(episode_ref) > 0
        AND (transport IS NULL OR char_length(transport) > 0)
        AND (conversation_ref IS NULL OR char_length(conversation_ref) > 0)
        """
      )
    )

    # A kept example has every body; a forgotten one has none.
    create(
      constraint(:work_examples, :work_example_bodies_valid,
        check: """
        (forgotten_at IS NULL AND briefing IS NOT NULL AND context IS NOT NULL
          AND output_schema IS NOT NULL AND trajectory IS NOT NULL AND result IS NOT NULL
          AND rejected_results IS NOT NULL AND outcome IS NOT NULL AND usage IS NOT NULL)
        OR (forgotten_at IS NOT NULL AND briefing IS NULL AND context IS NULL
          AND output_schema IS NULL AND trajectory IS NULL AND result IS NULL
          AND rejected_results IS NULL AND outcome IS NULL AND usage IS NULL)
        """
      )
    )

    create table(:work_example_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:example_id, references(:work_examples, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:signal_id, :uuid, null: false)
      add(:kind, :text, null: false)
      add(:value, :text)
      add(:category, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("clock_timestamp()"))
    end

    create(unique_index(:work_example_feedback, [:example_id, :signal_id]))

    create(
      constraint(:work_example_feedback, :work_example_feedback_valid,
        check: """
        kind ~ '^[a-z][a-z_]{0,63}$'
        AND category ~ '^[a-z][a-z_]{0,63}$'
        AND (value IS NULL OR char_length(value) BETWEEN 1 AND 256)
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("work_examples")}) THEN
        RAISE EXCEPTION 'work examples are kept for training; the previous release has nowhere to keep them';
      END IF;
    END
    $$
    """)

    drop(table(:work_example_feedback))
    drop(table(:work_examples))
    drop(constraint(:retention_settings, :retention_settings_work_examples_valid))

    alter table(:retention_settings) do
      remove(:work_examples_seconds)
      remove(:work_examples_enabled)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
