defmodule Ryker.Repo.Migrations.AddReadySessionWarmUntil do
  use Ecto.Migration

  # A routing session kept ready is prepared on its worker ahead of any
  # message: Coop starts its agent and keeps it running until `warm_until`
  # (`Ryker.Admission.ReadyPool`). A time already past records that Coop could
  # not start it. Only a session kept ready has one, and every row keeps what
  # it had. Rolling back forgets only which sessions are prepared; Coop still
  # stops each agent on its own clock.

  def change do
    alter table(:episode_work_sessions) do
      add(:warm_until, :utc_datetime_usec)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_warm_until_valid,
        check: "warm_until IS NULL OR ready_state IS NOT NULL"
      )
    )
  end
end
