defmodule Ryker.Repo.Migrations.AddAnswerFeedback do
  use Ecto.Migration

  # Andrew, 2026-09-27: "Do we have feedbacks, self-improvement loop, and data
  # collection to build/fine-tune our own super-efficient self hosted model
  # later?" Ryker kept operator reviews and the corrections it gave the model,
  # but nothing about how people took its answers.
  #
  # Each row is one signal about one of Ryker's answers, kept with the request
  # the answer belongs to: its episode, or the message routing answered by
  # itself. A signal is a reaction added or taken back, the person editing,
  # deleting or asking again after the answer, how routing read their next
  # message, or an operator's review of how the request ended. One source
  # event gives one signal of a kind (`kind`, `source_ref`), so a redelivered
  # event records nothing twice. `category` is how the Feedback page groups
  # it, written once when the signal is recorded.
  #
  # Rolling back refuses while any feedback is kept: the previous release has
  # nowhere to keep it.

  @kinds ~w(reaction_added reaction_removed message_edited message_deleted asked_again sentiment reviewed)
  @categories ~w(frustrated asked_again edited neutral satisfied reviewed)
  @sentiments ~w(satisfied neutral frustrated angry)

  def up do
    create table(:answer_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:kind, :text, null: false)
      add(:value, :text)
      add(:note, :text)
      add(:category, :text, null: false)
      add(:actor_ref, :text, null: false)
      add(:source, :text, null: false)
      add(:source_ref, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :delete_all)
      )

      add(:input_id, references(:ingress_inbox_entries, type: :uuid, on_delete: :delete_all))
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("clock_timestamp()"))
    end

    create(
      constraint(:answer_feedback, :answer_feedback_valid,
        check: """
        kind IN (#{quoted(@kinds)})
        AND category IN (#{quoted(@categories)})
        AND num_nonnulls(episode_id, input_id) = 1
        AND char_length(actor_ref) BETWEEN 1 AND 1024
        AND source ~ '^[a-z0-9_.-]+$' AND char_length(source) BETWEEN 1 AND 64
        AND char_length(source_ref) BETWEEN 1 AND 1024
        AND (note IS NULL OR (char_length(note) >= 1 AND octet_length(note) <= 2048))
        AND COALESCE(
          CASE kind
            WHEN 'sentiment' THEN value IN (#{quoted(@sentiments)})
            WHEN 'reviewed' THEN value IN ('complete', 'cancelled')
            WHEN 'reaction_added' THEN value ~ '^[a-z0-9_+-]{1,100}$'
            WHEN 'reaction_removed' THEN value ~ '^[a-z0-9_+-]{1,100}$'
            ELSE value IS NULL
          END,
          false
        )
        """
      )
    )

    create(unique_index(:answer_feedback, [:kind, :source_ref]))
    create(index(:answer_feedback, [:episode_id], where: "episode_id IS NOT NULL"))
    create(index(:answer_feedback, [:input_id], where: "input_id IS NOT NULL"))
    create(index(:answer_feedback, [:occurred_at, :id]))
    create(index(:answer_feedback, [:category, :occurred_at, :id]))
    create(index(:answer_feedback, [:inserted_at, :id]))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("answer_feedback")}) THEN
        RAISE EXCEPTION 'feedback on Ryker''s answers is kept; the previous release has nowhere to keep it';
      END IF;
    END
    $$
    """)

    drop(table(:answer_feedback))
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
