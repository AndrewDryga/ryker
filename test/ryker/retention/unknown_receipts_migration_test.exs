defmodule Ryker.Retention.UnknownReceiptsMigrationTest do
  # Every cleanup read kept an arm for `never_bound` receipts with an `unknown` remote state, and
  # that arm scanned every session ever kept: 17 scans a minute of 9,160 rows on the tenant
  # install (2026-11-04). Removing it would strand a session whose create did reach a worker, so
  # the migration sends those back to cleanup and leaves every saved receipt as recorded.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.CanonicalJSON

  @before_version 20_261_104_061_000
  @version 20_261_104_100_000

  test "a session with a retained create goes back to cleanup, and no saved receipt changes" do
    in_scratch_schema("unknown_receipts", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)

      never_created = session!(repo, prefix, unknown: true)
      created = session!(repo, prefix, unknown: true)
      genuine = session!(repo, prefix, unknown: false)
      create_command!(repo, prefix, created)

      recorded =
        Map.new([never_created, created, genuine], &{&1, stored(repo, prefix, &1)})

      assert @version in migrate!(repo, prefix, @version)

      assert %{
               cleanup_status: "close_pending",
               discarded: false,
               receipt: receipt,
               digest: digest
             } =
               stored(repo, prefix, created)

      assert receipt == recorded[created].receipt
      assert digest == recorded[created].digest
      assert stored(repo, prefix, never_created) == recorded[never_created]
      assert stored(repo, prefix, genuine) == recorded[genuine]
    end)
  end

  defp session!(repo, prefix, unknown: unknown?) do
    id = Ecto.UUID.generate()

    receipt = %{
      "kind" => "never_bound",
      "local_session_id" => id,
      "remote_session_id" => nil,
      "remote_state" => if(unknown?, do: "unknown", else: "absent")
    }

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.episode_work_sessions
        (id, execution_kind, policy, policy_digest, external_ref, cleanup_status, discarded_at,
         closed_at, cleanup_receipt, cleanup_receipt_fingerprint, ready_state, inserted_at, updated_at)
      VALUES ($1, 'admission', 'policy', $2, $3, 'discarded', now(), now(), $4, $5, 'retired', now(), now())
      """,
      [
        Ecto.UUID.dump!(id),
        String.duplicate("a", 64),
        "ready-admission:#{id}",
        CanonicalJSON.encode!(receipt),
        CanonicalJSON.digest(receipt)
      ]
    )

    id
  end

  defp create_command!(repo, prefix, session_id) do
    worker = "worker-#{System.unique_integer([:positive])}"
    placement = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.coop_workers
        (id, workspace_ref, certificate_sha256, state, inserted_at, updated_at)
      VALUES ($1, 'workspace', $2, 'eligible', now(), now())
      """,
      [worker, String.duplicate("c", 64)]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.coop_session_placements
        (id, session_id, worker_id, generation, lease_ref, lease_expires_at, state, requirements,
         requirements_fingerprint, inserted_at, updated_at)
      VALUES ($1, $2, $3, 1, 'lease', now(), 'retired', '{}', $4, now(), now())
      """,
      [Ecto.UUID.dump!(placement), Ecto.UUID.dump!(session_id), worker, String.duplicate("d", 64)]
    )

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.coop_worker_commands
        (id, placement_id, worker_id, session_id, placement_generation, kind, idempotency_key,
         payload, payload_fingerprint, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 1, 'create_session', $5, '{}', $6, 'queued', now(), now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(placement),
        worker,
        Ecto.UUID.dump!(session_id),
        "ryker:create:#{session_id}",
        String.duplicate("b", 64)
      ]
    )
  end

  defp stored(repo, prefix, id) do
    %{rows: [[status, discarded?, receipt, digest]]} =
      SQL.query!(
        repo,
        """
        SELECT cleanup_status, discarded_at IS NOT NULL, cleanup_receipt, cleanup_receipt_fingerprint
        FROM #{prefix}.episode_work_sessions WHERE id = $1
        """,
        [Ecto.UUID.dump!(id)]
      )

    %{
      cleanup_status: status,
      discarded: discarded?,
      receipt: Jason.decode!(receipt),
      digest: digest
    }
  end
end
