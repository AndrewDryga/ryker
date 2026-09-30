defmodule Ryker.Repo.Migrations.KeepFeedbackAndRefusedAnswersWithRoutingExamples do
  use Ecto.Migration

  # A routing example lacked two things a training set needs
  # (docs/training-data.md): how people took the answer, and the answers
  # routing refused before the one it accepted.
  #
  # Feedback lives in answer_feedback for the operational horizon (30 days by
  # default) and a routing example for its own window (a year by default), so
  # an export that joined them would lose the feedback of every example older
  # than a month. Each signal about an example's request is copied beside it
  # instead: what kind of signal, its value (an emoji, a feeling or a rating),
  # its category and when; never who gave it or a note's words. The copies
  # leave with their example.
  #
  # A refused answer was lost: each turn Ryker observes replaces the last one
  # it kept, so an answer sent back for repair was overwritten by the next.
  # The attempt now keeps each one with why it was refused, until retention
  # prunes the attempt's bodies, and the example copies them, redacted.
  #
  # Rolling back refuses while an example keeps feedback or refused answers:
  # the previous release has nowhere to keep them.

  def up do
    alter table(:admission_attempts) do
      add(:rejections, :text)
    end

    alter table(:routing_examples) do
      add(:rejected_answers, :text)
    end

    execute(
      "UPDATE #{qualified("routing_examples")} SET rejected_answers = '[]' WHERE forgotten_at IS NULL"
    )

    drop(constraint(:routing_examples, :routing_example_bodies_valid))

    # A kept example has every body; a forgotten one has none.
    create(
      constraint(:routing_examples, :routing_example_bodies_valid,
        check: """
        (forgotten_at IS NULL AND prompt IS NOT NULL AND output_schema IS NOT NULL
          AND answer IS NOT NULL AND decision IS NOT NULL AND outcome IS NOT NULL
          AND usage IS NOT NULL AND rejected_answers IS NOT NULL)
        OR (forgotten_at IS NOT NULL AND prompt IS NULL AND output_schema IS NULL
          AND answer IS NULL AND decision IS NULL AND outcome IS NULL AND usage IS NULL
          AND rejected_answers IS NULL)
        """
      )
    )

    # A request's feedback is copied to each of its examples by the request.
    create(index(:routing_examples, [:episode_id]))

    create table(:routing_example_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:example_id, references(:routing_examples, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:signal_id, :uuid, null: false)
      add(:kind, :text, null: false)
      add(:value, :text)
      add(:category, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("clock_timestamp()"))
    end

    create(unique_index(:routing_example_feedback, [:example_id, :signal_id]))

    create(
      constraint(:routing_example_feedback, :routing_example_feedback_valid,
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
      IF EXISTS (SELECT 1 FROM #{qualified("routing_example_feedback")})
         OR EXISTS (SELECT 1 FROM #{qualified("routing_examples")} WHERE rejected_answers <> '[]') THEN
        RAISE EXCEPTION 'routing examples keep feedback or refused answers the previous release cannot hold';
      END IF;
    END
    $$;
    """)

    drop(table(:routing_example_feedback))
    drop(index(:routing_examples, [:episode_id]))
    drop(constraint(:routing_examples, :routing_example_bodies_valid))

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

    alter table(:routing_examples) do
      remove(:rejected_answers)
    end

    alter table(:admission_attempts) do
      remove(:rejections)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
