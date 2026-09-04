defmodule Responder.Repo.Migrations.CreateOperatorActions do
  use Ecto.Migration

  def change do
    create table(:responder_operator_actions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:action_ref, :text, null: false)
      add(:request_fingerprint, :text, null: false)
      add(:actor_ref, :text, null: false)
      add(:action, :text, null: false)
      add(:kind, :text, null: false)
      add(:resource_ref, :text, null: false)
      add(:previous, :text, null: false)
      add(:outcome, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:responder_operator_actions, [:action_ref]))
    create(index(:responder_operator_actions, [:occurred_at, :id]))

    create(
      constraint(:responder_operator_actions, :responder_operator_action_valid,
        check: """
        char_length(action_ref) BETWEEN 1 AND 1024 AND
        char_length(request_fingerprint) = 64 AND
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        action IN ('retry', 'replay') AND
        char_length(kind) BETWEEN 1 AND 64 AND
        char_length(resource_ref) BETWEEN 1 AND 1024 AND
        jsonb_typeof(previous::jsonb) = 'object' AND
        jsonb_typeof(outcome::jsonb) = 'object'
        """
      )
    )
  end
end
