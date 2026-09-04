defmodule Responder.Repo.Migrations.CreateCardLabFeedback do
  use Ecto.Migration

  def change do
    create table(:card_lab_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:actor_ref, :text, null: false)
      add(:card_id, :text, null: false)
      add(:state_id, :text, null: false)
      add(:verdict, :text, null: false)
      add(:note, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:card_lab_feedback, [:card_id, :state_id, :inserted_at]))

    create(
      constraint(:card_lab_feedback, :card_lab_feedback_valid,
        check: """
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        char_length(card_id) BETWEEN 1 AND 120 AND
        char_length(state_id) BETWEEN 1 AND 120 AND
        verdict IN ('needs_work', 'good', 'approved') AND
        octet_length(note) BETWEEN 1 AND 4000
        """
      )
    )

    execute(
      "SELECT 1",
      """
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM #{qualified("card_lab_feedback")} LIMIT 1) THEN
          RAISE EXCEPTION 'card lab feedback has data and cannot be rolled back safely';
        END IF;
      END
      $$
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
