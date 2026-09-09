defmodule Responder.Repo.Migrations.AllowEventOnlyWaits do
  use Ecto.Migration

  def up do
    alter table(:episode_event_subscriptions) do
      modify(:deadline_at, :utc_datetime_usec, null: true)
      modify(:poll_after, :utc_datetime_usec, null: true)
    end

    replace_owner_constraint("")

    create(
      constraint(:episode_event_subscriptions, :event_subscription_schedule_valid,
        check: """
        (deadline_at IS NULL AND poll_after IS NULL AND source_kind IS NOT NULL AND matcher::jsonb <> '{}'::jsonb)
        OR (deadline_at IS NOT NULL AND poll_after IS NOT NULL AND poll_after <= deadline_at)
        """
      )
    )
  end

  def down do
    # Never invent timeouts or discard historical event-only subscriptions.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_event_subscriptions")} WHERE deadline_at IS NULL)
        OR EXISTS (SELECT 1 FROM #{qualified("episode_kernel_episodes")}
                   WHERE state = 'waiting_for_event' AND owner_deadline_at IS NULL)
      THEN RAISE EXCEPTION 'event-only waits cannot be rolled back safely'; END IF;
    END $$
    """)

    drop(constraint(:episode_event_subscriptions, :event_subscription_schedule_valid))
    replace_owner_constraint("AND owner_deadline_at IS NOT NULL")

    alter table(:episode_event_subscriptions) do
      modify(:deadline_at, :utc_datetime_usec, null: false)
      modify(:poll_after, :utc_datetime_usec, null: false)
    end
  end

  defp replace_owner_constraint(event_deadline_check) do
    drop(constraint(:episode_kernel_episodes, :episode_kernel_owner_matches_state))

    create(
      constraint(:episode_kernel_episodes, :episode_kernel_owner_matches_state,
        check: """
        (state IN ('complete', 'cancelled') AND owner_kind IS NULL AND owner_ref IS NULL AND owner_deadline_at IS NULL)
        OR (state = 'working' AND owner_kind IN ('turn', 'delivery') AND char_length(owner_ref) > 0 AND owner_deadline_at IS NULL)
        OR (state = 'waiting_for_input' AND owner_kind = 'input' AND char_length(owner_ref) > 0 AND owner_deadline_at IS NULL)
        OR (state = 'waiting_for_event' AND owner_kind = 'event' AND char_length(owner_ref) > 0 #{event_deadline_check})
        """
      )
    )
  end

  defp qualified(table) do
    escaped = String.replace(prefix() || "public", "\"", "\"\"")
    "\"#{escaped}\".\"#{table}\""
  end
end
