defmodule Ryker.Repo.Migrations.AddRoutingExamples do
  use Ecto.Migration

  # Andrew, 2026-09-27: "Do we have ... data collection to build/fine-tune our
  # own super-efficient self hosted model later?" Routing's exact prompt and
  # answer were pruned with the rest of a message's bodies after 30 days, and
  # nothing joined them to what happened next.
  #
  # A routing example is a redacted copy of one routing decision, its outcome
  # and its usage, kept under its own window while a person keeps "Keep
  # routing examples for training" on (Settings > Data retention). It names
  # the rows it was copied from without a foreign key: the copy outlives them.
  # One a person forgot keeps only its identity, so it is never copied again.
  #
  # The two partial indexes let the copy check, before it is taken, whether a
  # message its prompt quotes was forgotten or deleted; each holds only those
  # few rows.
  #
  # Rolling back refuses while any example is kept: the previous release has
  # nowhere to keep one, and dropping them would lose what was kept on purpose.

  def up do
    alter table(:retention_settings) do
      add(:routing_examples_enabled, :boolean, null: false, default: false)
      add(:routing_examples_seconds, :bigint, null: false, default: 365 * 86_400)
    end

    create(
      constraint(:retention_settings, :retention_settings_routing_examples_valid,
        check: "routing_examples_seconds BETWEEN 60 AND 315360000"
      )
    )

    create table(:routing_examples, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:input_id, :uuid, null: false)
      add(:episode_id, :uuid)
      add(:episode_ref, :text)
      add(:source_identity, :text, null: false)
      add(:message_keys, {:array, :text}, null: false, default: [])
      add(:conversation_refs, {:array, :text}, null: false, default: [])
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:thread_ref, :text)
      add(:repository_ref, :text)
      add(:execution_mode, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:execution_target, :text)
      add(:prompt, :text)
      add(:output_schema, :text)
      add(:answer, :text)
      add(:decision, :text)
      add(:outcome, :text)
      add(:usage, :text)
      add(:decided_at, :utc_datetime_usec, null: false)
      add(:forgotten_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:routing_examples, [:input_id]))
    create(index(:routing_examples, [:decided_at, :id]))
    create(index(:routing_examples, [:conversation_ref]))
    create(index(:routing_examples, [:source_identity]))
    create(index(:routing_examples, [:message_keys], using: :gin))
    create(index(:routing_examples, [:conversation_refs], using: :gin))

    create(
      constraint(:routing_examples, :routing_example_identity_valid,
        check: """
        source_identity ~ '^[0-9a-f]{64}$'
        AND execution_mode IN ('live', 'shadow')
        AND char_length(transport) > 0
        AND char_length(conversation_ref) > 0
        AND char_length(policy) > 0
        AND policy_digest ~ '^[0-9a-f]{64}$'
        """
      )
    )

    # A kept example has every body; a forgotten one has none.
    create(
      constraint(:routing_examples, :routing_example_bodies_valid,
        check: """
        (forgotten_at IS NULL AND prompt IS NOT NULL AND output_schema IS NOT NULL
          AND answer IS NOT NULL AND decision IS NOT NULL AND outcome IS NOT NULL
          AND usage IS NOT NULL)
        OR (forgotten_at IS NOT NULL AND prompt IS NULL AND output_schema IS NULL
          AND answer IS NULL AND decision IS NULL AND outcome IS NULL AND usage IS NULL)
        """
      )
    )

    create(
      index(:conversation_observations, [:conversation_ref, :source_message_ref],
        name: :conversation_observations_forgotten_messages,
        where: "forgotten_at IS NOT NULL"
      )
    )

    execute("""
    CREATE INDEX ingress_inbox_deleted_messages
    ON #{qualified("ingress_inbox_entries")}
    (destination_conversation_ref, (COALESCE(source_item_ref, native_input_id)))
    WHERE event_kind = 'delete'
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("routing_examples")}) THEN
        RAISE EXCEPTION 'routing examples are kept for training; the previous release has nowhere to keep them';
      END IF;
    END
    $$
    """)

    execute("DROP INDEX #{qualified("ingress_inbox_deleted_messages")}")

    drop(
      index(:conversation_observations, [], name: :conversation_observations_forgotten_messages)
    )

    drop(table(:routing_examples))
    drop(constraint(:retention_settings, :retention_settings_routing_examples_valid))

    alter table(:retention_settings) do
      remove(:routing_examples_seconds)
      remove(:routing_examples_enabled)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
