defmodule Ryker.Repo.Migrations.RetireDiscardedSessionPlacements do
  use Ecto.Migration

  # Found live 2026-09-27: 133 of the worker's 136 active placements belonged
  # to sessions retention had already discarded. Nothing retired a placement
  # when its session was discarded, and every worker poll renews every active
  # placement a row at a time, so an idle install wrote 122 placement rows a
  # second and the pile grew by one with each finished conversation. Retention
  # now retires a session's placements as it settles the session
  # (`Ryker.Retention.Custody`); this retires the ones it left behind and fails
  # any command still waiting on them, as a retired placement's commands always
  # fail (`Ryker.CoopFleet.ControlPlane.Commands.fail_undelivered_commands/2`).
  # No row is removed.
  #
  # Nothing to undo: a discarded session's placement is retired under either
  # release.

  alias Ryker.CanonicalJSON

  @current ~w(assigning active draining revoking)
  @error %{
    "code" => "operation_not_enqueued",
    "detail" => "command never left Ryker before its placement ended",
    "status" => 409
  }

  def up, do: execute(&retire_leaked_placements/0)

  def down, do: :ok

  defp retire_leaked_placements do
    %{rows: rows} =
      repo().query!(
        """
        UPDATE #{qualified("coop_session_placements")} AS placement
        SET state = 'retired', updated_at = now() AT TIME ZONE 'UTC'
        FROM #{qualified("episode_work_sessions")} AS session
        WHERE session.id = placement.session_id
          AND session.cleanup_status = 'discarded'
          AND placement.state = ANY($1)
        RETURNING placement.id
        """,
        [@current],
        log: false
      )

    Enum.each(rows, fn [placement_id] -> fail_queued_commands(placement_id) end)
  end

  defp fail_queued_commands(placement_id) do
    %{rows: commands} =
      repo().query!(
        """
        SELECT id, idempotency_key FROM #{qualified("coop_worker_commands")}
        WHERE placement_id = $1 AND status = 'queued'
        """,
        [placement_id],
        log: false
      )

    Enum.each(commands, fn [id, idempotency_key] ->
      fingerprint =
        CanonicalJSON.digest(%{
          "command_id" => Ecto.UUID.load!(id),
          "error" => @error,
          "operation_key" => idempotency_key,
          "resource" => nil,
          "state" => "failed"
        })

      repo().query!(
        """
        UPDATE #{qualified("coop_worker_commands")}
        SET status = 'failed', error = $2, operation_key = $3, result_fingerprint = $4,
            completed_at = now() AT TIME ZONE 'UTC', updated_at = now() AT TIME ZONE 'UTC'
        WHERE id = $1
        """,
        [id, CanonicalJSON.encode!(@error), idempotency_key, fingerprint],
        log: false
      )
    end)
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
