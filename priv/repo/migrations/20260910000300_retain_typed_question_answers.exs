defmodule Ryker.Repo.Migrations.RetainTypedQuestionAnswers do
  use Ecto.Migration

  # A typed reply answers a question without selecting a choice. The response
  # keeps its exact question, actor and source revision; choice fields are absent.
  def up do
    drop(constraint(:episode_state_record_responses, :episode_state_record_response_valid))

    alter table(:episode_state_record_responses) do
      modify(:choice_index, :integer, null: true, from: {:integer, null: false})
      modify(:choice, :text, null: true, from: {:text, null: false})
    end

    create(response_constraint(true))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_state_record_responses")}
        WHERE choice_index IS NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'typed question answers have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_state_record_responses, :episode_state_record_response_valid))

    alter table(:episode_state_record_responses) do
      modify(:choice_index, :integer, null: false, from: {:integer, null: true})
      modify(:choice, :text, null: false, from: {:text, null: true})
    end

    create(response_constraint(false))
  end

  defp response_constraint(typed_answers?) do
    choice =
      if typed_answers?,
        do: """
        ((choice_index IS NULL AND choice IS NULL) OR
         (choice_index IS NOT NULL AND choice IS NOT NULL AND
          choice_index BETWEEN 0 AND 9 AND char_length(choice) BETWEEN 1 AND 240))
        """,
        else: "choice_index BETWEEN 0 AND 9 AND char_length(choice) BETWEEN 1 AND 240"

    constraint(:episode_state_record_responses, :episode_state_record_response_valid,
      check: """
      char_length(response_ref) BETWEEN 1 AND 1024 AND
      char_length(actor_ref) BETWEEN 1 AND 1024 AND
      #{choice}
      """
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
