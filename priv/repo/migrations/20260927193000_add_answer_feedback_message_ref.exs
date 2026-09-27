defmodule Ryker.Repo.Migrations.AddAnswerFeedbackMessageRef do
  use Ecto.Migration

  # Chat's quick replies and the updates Work posts take reactions as Work
  # replies do (2026-09-27). A quick reply can be several messages and a
  # request holds its updates beside its replies, so a reaction's feedback now
  # names the one message of Ryker's it was on, and Chat reads the pills of a
  # message no reaction event holds back from it.
  #
  # A reaction recorded on a Work reply before this names its message from the
  # request's own reaction event; one recorded on a quick reply or an update
  # before this has no record of which message it was, and names none.
  #
  # Rolling back forgets only which message each reaction was on.

  def up do
    alter table(:answer_feedback) do
      add(:message_ref, :text)
    end

    create(
      constraint(:answer_feedback, :answer_feedback_message_ref_valid,
        check: """
        message_ref IS NULL OR (
          kind IN ('reaction_added', 'reaction_removed')
          AND char_length(message_ref) BETWEEN 1 AND 1024
        )
        """
      )
    )

    create(index(:answer_feedback, [:message_ref], where: "message_ref IS NOT NULL"))

    execute("""
    UPDATE #{qualified("answer_feedback")} AS feedback
    SET message_ref = event.payload::jsonb ->> 'target_message_ref'
    FROM #{qualified("episode_kernel_events")} AS event
    WHERE feedback.kind IN ('reaction_added', 'reaction_removed')
      AND feedback.message_ref IS NULL
      AND event.episode_id = feedback.episode_id
      AND event.kind = 'reaction_recorded'
      AND event.payload::jsonb ->> 'event_ref' = feedback.source_ref
      AND char_length(event.payload::jsonb ->> 'target_message_ref') BETWEEN 1 AND 1024
    """)
  end

  def down do
    drop(index(:answer_feedback, [:message_ref]))
    drop(constraint(:answer_feedback, :answer_feedback_message_ref_valid))

    alter table(:answer_feedback) do
      remove(:message_ref)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
