defmodule Responder.Repo.Migrations.CreateRuntimeProgress do
  use Ecto.Migration

  def change do
    create table(:responder_runtime_progress, primary_key: false) do
      add(:lane, :text, primary_key: true)
      add(:outcome, :text, null: false)
      add(:cycle_count, :bigint, null: false, default: 0)
      add(:observed_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:responder_runtime_progress, :responder_runtime_progress_identity_valid,
        check: """
        char_length(lane) BETWEEN 1 AND 64 AND
        lane ~ '^[a-z][a-z0-9_]*$' AND
        outcome IN ('cycle', 'error') AND
        cycle_count > 0
        """
      )
    )
  end
end
