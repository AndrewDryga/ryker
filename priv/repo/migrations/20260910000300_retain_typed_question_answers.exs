defmodule Responder.Repo.Migrations.RetainTypedQuestionAnswers do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE episode_state_record_responses
      ALTER COLUMN choice_index DROP NOT NULL,
      ALTER COLUMN choice DROP NOT NULL,
      DROP CONSTRAINT episode_state_record_response_valid,
      ADD CONSTRAINT episode_state_record_response_valid CHECK (
        char_length(response_ref) BETWEEN 1 AND 1024 AND
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        ((choice_index IS NULL AND choice IS NULL) OR
         (choice_index IS NOT NULL AND choice IS NOT NULL AND
          choice_index BETWEEN 0 AND 9 AND char_length(choice) BETWEEN 1 AND 240))
      )
    """)
  end

  def down do
    raise "typed answer provenance cannot be removed without losing user history"
  end
end
