defmodule Ryker.Repo.Migrations.AddEventSubscriptionsAndScheduleHistory do
  use Ecto.Migration

  def up do
    create table(:episode_event_subscriptions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:episode_id, references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:record_id, references(:episode_state_records, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:ref, :text, null: false)
      add(:status, :text, null: false)
      add(:source_kind, :text)
      add(:matcher, :text, null: false)
      add(:cursor, :text)
      add(:poll_after, :utc_datetime_usec, null: false)
      add(:deadline_at, :utc_datetime_usec, null: false)
      add(:last_observation, :text)
      add(:last_observed_at, :utc_datetime_usec)
      add(:resolution_kind, :text)
      add(:revision, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:episode_event_subscriptions, [:ref]))
    create(unique_index(:episode_event_subscriptions, [:record_id]))

    create(
      unique_index(:episode_event_subscriptions, [:episode_id],
        where: "status = 'active'",
        name: :episode_event_subscriptions_one_active_episode_index
      )
    )

    create(index(:episode_event_subscriptions, [:status, :poll_after]))
    create(index(:episode_event_subscriptions, [:status, :deadline_at]))

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
          OR (status = 'resolved' AND resolution_kind IN ('input', 'poll_fallback'))
          OR (status = 'timed_out' AND resolution_kind = 'deadline')
          OR (status = 'cancelled' AND resolution_kind = 'cancelled')
        )
        """
      )
    )

    alter table(:episode_schedule_occurrences) do
      add(:trigger, :text, null: false, default: "scheduled")
    end

    create(
      constraint(:episode_schedule_occurrences, :episode_schedule_occurrence_trigger_valid,
        check: "trigger IN ('scheduled', 'manual')"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_event_subscriptions")} LIMIT 1
      ) OR EXISTS (
        SELECT 1 FROM #{qualified("episode_schedule_occurrences")}
        WHERE trigger = 'manual'
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'subscription or manual schedule history has data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_schedule_occurrences, :episode_schedule_occurrence_trigger_valid))

    alter table(:episode_schedule_occurrences) do
      remove(:trigger)
    end

    drop(table(:episode_event_subscriptions))
  end

  defp qualified(table) do
    escaped = String.replace(prefix() || "public", "\"", "\"\"")
    ~s("#{escaped}".#{table})
  end
end
