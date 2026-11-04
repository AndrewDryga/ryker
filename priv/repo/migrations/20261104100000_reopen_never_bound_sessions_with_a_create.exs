defmodule Ryker.Repo.Migrations.ReopenNeverBoundSessionsWithACreate do
  @moduledoc """
  Cleanup once settled a session it never bound as `never_bound` with an
  `unknown` remote state, which does not say whether the worker made one. Later
  code proves absence first, but every cleanup read kept an arm for the old
  receipts, and that arm is why those reads scanned every session ever kept:
  17 scans a minute of 9,160 rows on the tenant install (2026-11-04). The tenant
  holds none of these receipts and the laptop one, with no placement and no
  create command.

  With the arm gone, a retained create is the one case that still owes cleanup:
  it goes back to cleanup, which reconciles it on its original worker. Every
  other such receipt stays as it was recorded, since a saved outcome is not
  rewritten from later state. No create command is what custody calls absence
  today (`Ryker.Retention.Creation.resolve/1`), so retention may now age it out.
  """
  use Ecto.Migration

  @unknown """
  session.cleanup_status = 'discarded'
    AND session.coop_session_id IS NULL
    AND session.cleanup_receipt::jsonb ->> 'kind' = 'never_bound'
    AND session.cleanup_receipt::jsonb ->> 'remote_state' = 'unknown'
  """

  @create """
  SELECT 1 FROM coop_worker_commands AS command
  WHERE command.session_id = session.id AND command.kind = 'create_session'
  """

  def up do
    execute("""
    UPDATE episode_work_sessions AS session
    SET cleanup_status = 'close_pending', discarded_at = NULL, cleanup_next_attempt_at = NULL,
      updated_at = now()
    WHERE #{@unknown} AND EXISTS (#{@create})
    """)
  end

  # Nothing to restore: cleanup settles a reopened session again either way.
  def down, do: :ok
end
