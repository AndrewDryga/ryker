defmodule Ryker.Repo.Migrations.RecordStateToolCalls do
  use Ecto.Migration

  # Coop's worker keeps tool arguments and error output on the worker: its
  # narration of a call names the server and tool and reports only the status.
  # On 2026-09-25 a weekday schedule failed four times in one conversation and
  # every timeline row said only "the tool failed". Ryker serves its state
  # tools itself, so it now keeps each call's arguments and the error it
  # answered, bounded and redacted, for as long as the turn keeps its bodies.
  def up do
    create table(:episode_work_state_tool_calls, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:turn_id, references(:episode_work_turns, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:tool, :text, null: false)
      add(:status, :text, null: false)
      add(:arguments, :text)
      add(:error, :text)
      add(:called_at, :utc_datetime_usec, null: false)
    end

    create(index(:episode_work_state_tool_calls, [:turn_id, :called_at]))

    create(
      constraint(:episode_work_state_tool_calls, :episode_work_state_tool_call_valid,
        check: """
        char_length(tool) BETWEEN 1 AND 256
        AND status IN ('completed', 'failed')
        AND ((status = 'completed' AND error IS NULL)
             OR (status = 'failed' AND error IS NOT NULL))
        AND (arguments IS NULL OR octet_length(arguments) <= 131072)
        AND (error IS NULL OR octet_length(error) <= 131072)
        """
      )
    )

    execute("""
    CREATE TRIGGER ryker_control_plane_changed AFTER INSERT OR UPDATE OR DELETE
      ON #{qualified("episode_work_state_tool_calls")} FOR EACH STATEMENT
      EXECUTE FUNCTION #{qualified("ryker_control_plane_notify")}()
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_work_state_tool_calls")} LIMIT 1) THEN
        RAISE EXCEPTION 'state-tool call history must be exported before rollback';
      END IF;
    END $$;
    """)

    drop(table(:episode_work_state_tool_calls))
  end

  defp qualified(name),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".#{name})
end
