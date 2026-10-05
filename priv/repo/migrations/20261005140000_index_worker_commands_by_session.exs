defmodule Ryker.Repo.Migrations.IndexWorkerCommandsBySession do
  use Ecto.Migration

  # Workspace, authority and retention read a session's commands by session
  # and kind, and nothing indexed the session: each read scanned the whole
  # table, and so did the foreign key check when a session row went
  # (2026-10-04 review).
  def change do
    create(index(:coop_worker_commands, [:session_id, :kind]))
  end
end
