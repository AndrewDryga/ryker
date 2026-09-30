defmodule Ryker.Repo.Migrations.LearnWhatPeopleSayAboutThemselves do
  use Ecto.Migration

  # Andrew, 2026-09-30: Ryker should also learn about people "passively ...
  # without approvals (like when you mentioned when it's your birthday or
  # what is your favorite tv show etc)".
  #
  # One row per person and kind of fact (`key`): the latest thing that person
  # said about themselves, the message it came from, where it was said and
  # whether that place is private, in which case it is used only there.
  # Forgetting erases the words and keeps the row, so the message they came
  # from never teaches them again.
  #
  # Rolling back refuses while anything is kept: the previous release has
  # nowhere to keep it.

  def up do
    create table(:person_facts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:person_ref, :text, null: false)
      add(:key, :text, null: false)
      add(:fact, :text)
      add(:status, :text, null: false)
      add(:source_input_id, :uuid, null: false)
      add(:source_message_ref, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:private, :boolean, null: false)
      add(:said_at, :utc_datetime_usec, null: false)
      add(:forgotten_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("clock_timestamp()"))
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("clock_timestamp()"))
    end

    create(unique_index(:person_facts, [:person_ref, :key]))
    create(index(:person_facts, [:source_message_ref]))
    create(index(:person_facts, [:conversation_ref]))

    create(
      constraint(:person_facts, :person_facts_valid,
        check: """
        char_length(person_ref) BETWEEN 1 AND 1024
        AND key ~ '^[a-z][a-z0-9-]{0,47}$'
        AND char_length(source_message_ref) BETWEEN 1 AND 1024
        AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND COALESCE(
          CASE status
            WHEN 'kept' THEN
              char_length(fact) BETWEEN 1 AND 280 AND forgotten_at IS NULL
            WHEN 'forgotten' THEN fact IS NULL AND forgotten_at IS NOT NULL
          END,
          false
        )
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("person_facts")}) THEN
        RAISE EXCEPTION 'what people said about themselves is kept; the previous release has nowhere to keep it';
      END IF;
    END
    $$
    """)

    drop(table(:person_facts))
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
