defmodule Ryker.Repo.Migrations.ForgetLearnedKnowledge do
  use Ecto.Migration

  # A person can make Ryker forget what learning kept: one learned topic, or
  # what learning took from the message a forgotten fact came from. The topic
  # keeps its identity and when it was forgotten, its text is erased, and the
  # messages it was learned from are never learned from again, so learning
  # cannot bring it back (QA re-test, 2026-09-26).
  #
  # Rolling back would make forgotten messages learnable again, so `down`
  # refuses while anything is forgotten.
  def up do
    alter table(:conversation_knowledge) do
      add(:forgotten_at, :utc_datetime_usec)
    end

    alter table(:conversation_observations) do
      add(:forgotten_at, :utc_datetime_usec)
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("conversation_knowledge")} WHERE forgotten_at IS NOT NULL)
        OR EXISTS (SELECT 1 FROM #{qualified("conversation_observations")} WHERE forgotten_at IS NOT NULL)
      THEN
        RAISE EXCEPTION 'forgotten knowledge exists; rolling back would let learning bring it back';
      END IF;
    END
    $$
    """)

    alter table(:conversation_observations) do
      remove(:forgotten_at)
    end

    alter table(:conversation_knowledge) do
      remove(:forgotten_at)
    end
  end

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
