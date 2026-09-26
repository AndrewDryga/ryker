defmodule Ryker.Repo.Migrations.AddReadyRoutingSessions do
  use Ecto.Migration

  # Routing sessions kept ready (Settings › Advanced): how many routing sessions
  # Ryker starts ahead of time, and where each one stands on the shared session
  # table. A session kept ready is a routing session with no message until
  # exactly one message's routing generation claims it: `starting` while Coop
  # creates it, `ready` once it is open, `claimed` by that generation, or
  # `retired` when it is given up unused and cleanup closes it.

  def up do
    alter table(:work_settings) do
      add(:ready_routing_sessions, :integer, null: false, default: 1)
    end

    create(
      constraint(:work_settings, :work_settings_ready_routing_sessions_valid,
        check: "ready_routing_sessions BETWEEN 0 AND 5"
      )
    )

    alter table(:episode_work_sessions) do
      add(:ready_state, :text)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_ready_state_valid,
        check: """
        ready_state IS NULL OR (
          execution_kind = 'admission' AND
          ready_state IN ('starting', 'ready', 'claimed', 'retired') AND
          (ready_state = 'claimed' OR admission_input_id IS NULL) AND
          (ready_state <> 'ready' OR coop_session_id IS NOT NULL)
        )
        """
      )
    )

    # One routing generation has one session, whether routing created it or
    # claimed one kept ready. Every routing session so far was named after its
    # generation, so the rows already present satisfy it.
    create(
      unique_index(:episode_work_sessions, [:admission_input_id, :generation],
        name: :episode_work_sessions_admission_generation_index,
        where: "execution_kind = 'admission' AND admission_input_id IS NOT NULL"
      )
    )

    create(
      index(:episode_work_sessions, [:policy, :policy_digest, :inserted_at],
        name: :episode_work_sessions_ready_index,
        where: "ready_state = 'ready'"
      )
    )
  end

  def down do
    # Without its state a session no message claimed has no owner, and cleanup
    # never closes a session without one: it would stay open on the worker.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_work_sessions")}
        WHERE ready_state IN ('starting', 'ready', 'retired') AND cleanup_status <> 'discarded'
      ) THEN
        RAISE EXCEPTION 'routing sessions kept ready are still open; set Routing sessions kept ready to 0 and let cleanup remove them before rolling back';
      END IF;
    END
    $$
    """)

    drop(index(:episode_work_sessions, [], name: :episode_work_sessions_ready_index))

    drop(
      index(:episode_work_sessions, [], name: :episode_work_sessions_admission_generation_index)
    )

    drop(constraint(:episode_work_sessions, :episode_work_session_ready_state_valid))

    alter table(:episode_work_sessions) do
      remove(:ready_state)
    end

    drop(constraint(:work_settings, :work_settings_ready_routing_sessions_valid))

    alter table(:work_settings) do
      remove(:ready_routing_sessions)
    end
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
