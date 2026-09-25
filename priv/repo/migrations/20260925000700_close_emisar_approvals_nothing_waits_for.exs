defmodule Ryker.Repo.Migrations.CloseEmisarApprovalsNothingWaitsFor do
  use Ecto.Migration

  # An approval watch whose task no longer waits for it (the task was closed,
  # or its wait was answered) could only stay blocked: a retry was always
  # refused and it sat on Failures for good. Ryker now closes it itself, keeps
  # the row, and records when and why here. A CHECK passes on NULL, so the
  # reason is required outright rather than only matched against the list.
  @remote_statuses ~w(pending pending_approval sent running cancelling success failed error validation_failed unknown_action cancelled timed_out refused denied)

  def up do
    alter table(:episode_emisar_approvals) do
      add(:closed_at, :utc_datetime_usec)
      add(:closed_reason, :text)
    end

    drop(constraint(:episode_emisar_approvals, :episode_emisar_approval_identity_valid))

    create(
      constraint(:episode_emisar_approvals, :episode_emisar_approval_identity_valid,
        check: identity_check(~w(monitoring resumed blocked closed))
      )
    )

    create(
      constraint(:episode_emisar_approvals, :episode_emisar_approval_closure_valid,
        check:
          "(status = 'closed' AND closed_at IS NOT NULL AND closed_reason IS NOT NULL " <>
            "AND closed_reason IN ('wait_ended')) OR " <>
            "(status <> 'closed' AND closed_at IS NULL AND closed_reason IS NULL)"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified_approvals()}
        WHERE status = 'closed'
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'closed Emisar approvals have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_emisar_approvals, :episode_emisar_approval_closure_valid))
    drop(constraint(:episode_emisar_approvals, :episode_emisar_approval_identity_valid))

    create(
      constraint(:episode_emisar_approvals, :episode_emisar_approval_identity_valid,
        check: identity_check(~w(monitoring resumed blocked))
      )
    )

    alter table(:episode_emisar_approvals) do
      remove(:closed_reason)
      remove(:closed_at)
    end
  end

  defp identity_check(statuses) do
    "char_length(request_id) BETWEEN 1 AND 80 " <>
      "AND octet_length(run_id) BETWEEN 1 AND 200 " <>
      "AND octet_length(operation_id) BETWEEN 1 AND 200 " <>
      "AND octet_length(action_id) BETWEEN 1 AND 200 " <>
      "AND octet_length(pack_ref) BETWEEN 1 AND 300 " <>
      "AND octet_length(runner_ref) BETWEEN 1 AND 300 " <>
      "AND octet_length(approval_url) BETWEEN 1 AND 2048 " <>
      "AND status IN (#{quoted(statuses)}) " <>
      "AND remote_status IN (#{quoted(@remote_statuses)}) " <>
      "AND failure_count >= 0 " <>
      "AND (run_url IS NULL OR octet_length(run_url) BETWEEN 1 AND 2048) " <>
      "AND (remote_error IS NULL OR octet_length(remote_error) BETWEEN 1 AND 1000) " <>
      "AND (last_error IS NULL OR octet_length(last_error) BETWEEN 1 AND 4096) " <>
      "AND ((status = 'resumed' AND terminal_at IS NOT NULL AND resumed_at IS NOT NULL) " <>
      "OR (status <> 'resumed' AND resumed_at IS NULL))"
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified_approvals do
    case prefix() do
      nil -> "episode_emisar_approvals"
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".episode_emisar_approvals)
    end
  end
end
