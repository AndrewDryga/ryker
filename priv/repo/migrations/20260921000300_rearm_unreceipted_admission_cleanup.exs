defmodule Ryker.Repo.Migrations.RearmUnreceiptedAdmissionCleanup do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE #{sessions_table()}
    SET cleanup_status = 'close_pending',
        cleanup_attempt_count = 0,
        cleanup_lease_ref = NULL,
        cleanup_lease_owner = NULL,
        cleanup_lease_expires_at = NULL,
        cleanup_next_attempt_at = NULL,
        cleanup_last_error_code = NULL,
        cleanup_last_error_detail = NULL,
        close_expected_revision = NULL,
        closed_at = NULL,
        discard_after = NULL,
        discard_plan_expected_revision = NULL,
        discard_plan_operation_id = NULL,
        discard_plan = NULL,
        discard_plan_fingerprint = NULL,
        retained_reason = NULL,
        discarded_at = NULL,
        cleanup_blocked_from = NULL,
        updated_at = NOW()
    WHERE execution_kind = 'admission'
      AND cleanup_status = 'discarded'
      AND coop_session_id IS NOT NULL
      AND cleanup_receipt IS NULL
    """)
  end

  # This repairs false local terminal state so normal custody can obtain a real
  # remote discard receipt. Reversing it would recreate the leak.
  def down, do: :ok

  defp sessions_table,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".episode_work_sessions)
end
