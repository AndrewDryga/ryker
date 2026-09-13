defmodule Ryker.Repo.Migrations.AllowTimerWaitResolutions do
  use Ecto.Migration

  def up do
    replace_constraint("'input', 'poll_fallback', 'timer'")
  end

  def down do
    # A rollback cannot erase or relabel completed timer history.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_event_subscriptions")}
        WHERE resolution_kind = 'timer'
      ) THEN
        RAISE EXCEPTION 'timer resolution history cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    replace_constraint("'input', 'poll_fallback'")
  end

  defp replace_constraint(resolved_kinds) do
    drop(constraint(:episode_event_subscriptions, :episode_event_subscription_valid))

    create(
      constraint(:episode_event_subscriptions, :episode_event_subscription_valid,
        check: """
        octet_length(ref) BETWEEN 1 AND 256
        AND status IN ('active', 'resolved', 'timed_out', 'cancelled')
        AND (source_kind IS NULL OR octet_length(source_kind) BETWEEN 1 AND 120)
        AND octet_length(matcher) BETWEEN 2 AND 32768
        AND jsonb_typeof(matcher::jsonb) = 'object'
        AND (cursor IS NULL OR octet_length(cursor) BETWEEN 1 AND 16384)
        AND (cursor IS NULL OR jsonb_typeof(cursor::jsonb) IN ('object', 'array', 'string', 'number', 'boolean', 'null'))
        AND (last_observation IS NULL OR octet_length(last_observation) BETWEEN 2 AND 32768)
        AND (last_observation IS NULL OR jsonb_typeof(last_observation::jsonb) = 'object')
        AND poll_after <= deadline_at
        AND revision > 0
        AND (
          (status = 'active' AND resolution_kind IS NULL)
          OR (status = 'resolved' AND resolution_kind IN (#{resolved_kinds}))
          OR (status = 'timed_out' AND resolution_kind = 'deadline')
          OR (status = 'cancelled' AND resolution_kind = 'cancelled')
        )
        """
      )
    )
  end

  defp qualified(table) do
    escaped = String.replace(prefix() || "public", "\"", "\"\"")
    "\"#{escaped}\".\"#{table}\""
  end
end
