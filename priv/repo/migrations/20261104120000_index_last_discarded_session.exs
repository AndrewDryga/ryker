defmodule Ryker.Repo.Migrations.IndexLastDiscardedSession do
  @moduledoc """
  Readiness and metrics ask when cleanup last reclaimed a session, which read
  every session ever kept, about 2.6 times a minute on the tenant install
  (2026-11-04).
  """
  use Ecto.Migration

  def change do
    create(
      index(:episode_work_sessions, [:discarded_at],
        name: :episode_work_sessions_last_discarded,
        where: "discarded_at IS NOT NULL"
      )
    )
  end
end
