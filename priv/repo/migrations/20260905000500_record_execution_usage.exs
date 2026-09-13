defmodule Ryker.Repo.Migrations.RecordExecutionUsage do
  use Ecto.Migration

  def up do
    # Compact accounting has no cascading artifact foreign key. Expiring a
    # prompt or deleting an operational turn must not erase its spend.
    create table(:execution_usage, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :text, null: false)
      add(:source_id, :binary_id, null: false)
      add(:generation, :text, null: false)
      add(:episode_id, :binary_id)
      add(:session_id, :binary_id)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:repository_ref, :text)
      add(:execution_mode, :text, null: false)
      add(:remote_ref, :text)
      add(:status, :text, null: false)
      add(:execution_target, :text)
      add(:usage_recorded, :boolean, null: false, default: false)
      add(:usage_cost_recorded, :boolean, null: false, default: false)
      add(:usage_cost_usd, :decimal, precision: 30, scale: 12)
      add(:timing_recorded, :boolean, null: false, default: false)
      add(:measurement_error_code, :text)

      for field <- [
            :usage_input_tokens,
            :usage_cached_input_tokens,
            :usage_output_tokens,
            :usage_reasoning_tokens,
            :usage_queued_ms,
            :usage_provider_ms,
            :usage_host_ms
          ] do
        add(field, :bigint)
      end

      for field <- [:remote_queued_at, :remote_started_at, :remote_finished_at] do
        add(field, :utc_datetime_usec)
      end

      add(:recorded_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:execution_usage, [:kind, :source_id, :generation]))
    create(index(:execution_usage, [:recorded_at, :id]))
    create(index(:execution_usage, [:episode_id, :recorded_at]))

    create(
      constraint(:execution_usage, :execution_usage_identity_valid,
        check:
          "kind IN ('work', 'admission') AND execution_mode IN ('live', 'shadow') AND octet_length(generation) BETWEEN 1 AND 64"
      )
    )

    create(
      constraint(:execution_usage, :execution_usage_cost_valid,
        check:
          "(usage_cost_recorded AND usage_cost_usd >= 0 AND usage_cost_usd <= 1000000000) OR (NOT usage_cost_recorded AND usage_cost_usd IS NULL)"
      )
    )

    execute("""
    CREATE TRIGGER responder_control_plane_changed AFTER INSERT OR UPDATE OR DELETE
      ON #{schema()}.execution_usage FOR EACH STATEMENT EXECUTE FUNCTION #{schema()}.responder_control_plane_notify()
    """)
  end

  def down do
    execute(
      "DO $$ BEGIN IF EXISTS (SELECT 1 FROM #{schema()}.execution_usage LIMIT 1) THEN RAISE EXCEPTION 'export execution accounting before rollback'; END IF; END $$"
    )

    drop(table(:execution_usage))
  end

  defp schema, do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}")
end
