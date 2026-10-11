defmodule Ryker.Retention.WorkerChangeTest do
  @moduledoc """
  Cleanup against the real fleet placement, with this test acting as the worker.

  Retention reaches a session only through a placement on the worker that
  holds it. These tests change that worker the ways production changed it (a
  newer policy version, an outage, a removal, a lost session) and hold the
  invariant that none of them leaves a cleanup waiting for a person who cannot
  help.
  """
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  alias Ryker.CoopFleet.{Client, Command, ControlPlane, Placement, Worker, WorkerLifecycle}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Retention.{Creation, Custody, Dispatcher}
  alias Ryker.Work.Session

  # The live shapes of 2026-09-23: ryker-chat sessions pinned to a8d0aa03…,
  # the worker moved to 3fd0d64f… by a Settings › Models change, authority
  # 947a151e… unchanged, no repository.
  @policy "ryker-chat"
  @started String.duplicate("a", 64)
  @newer String.duplicate("3", 64)
  @authority String.duplicate("9", 64)
  @workspace "workspace-retention-worker-change"

  # Found live 2026-09-24: two "Closing a worker session stopped · Retry won't
  # help" cards sat on Failures for a day. A model change in Settings rewrote
  # the ryker-chat policy, placement then refused every command for sessions
  # started under the old version, and retention blocked each cleanup after one
  # attempt behind a button that could never work. Close, discard planning and
  # discard do no policy work, so the worker that holds the session takes them
  # under whatever it runs now.
  test "historical cleanup completes after its worker sandbox changes" do
    worker = enroll!("policy-change")
    session = terminal_session!("policy-change", worker)

    # Settings › Models rewrote the policy; the worker reports the newer version.
    poll!(worker, @newer)
    expire_placements!(session)

    fleet = fleet_client(worker, @newer, remote_session(session))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:policy-change:grace")
    assert {:ok, {:executed, %{phase: :closed}}} = run(fleet, "cleanup:policy-change:close")
    assert {:ok, {:executed, %{phase: :planned}}} = run(fleet, "cleanup:policy-change:plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:policy-change:discard")

    cleaned = Repo.get!(Session, session.id)
    assert cleaned.cleanup_status == :discarded
    assert cleaned.cleanup_receipt["kind"] == "discarded"
    # The session keeps the version it ran under; only the cleanup followed the worker.
    assert cleaned.policy_digest == @started

    assert commands(session) == ~w(get_session close_session get_session plan_discard
             get_session discard_session)

    holder = current_placement!(session)
    assert holder.worker_id == worker
    assert holder.requirements["sandbox_digest"] == @newer
    refute Map.has_key?(holder.requirements, "policy_digest")
  end

  # Found live 2026-09-27: 133 of the worker's 136 active placements belonged
  # to sessions retention had already discarded. Nothing retired a placement
  # when its session was discarded, and each worker poll renews every active
  # placement a row at a time, so an idle install wrote 122 placement rows a
  # second, and the pile grew by one with every finished conversation.
  test "a discarded session's placement is retired, so the worker's polls stop renewing it" do
    worker = enroll!("discarded")
    session = terminal_session!("discarded", worker)
    fleet = fleet_client(worker, @started, remote_session(session))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:discarded:grace")
    assert {:ok, {:executed, %{phase: :closed}}} = run(fleet, "cleanup:discarded:close")
    assert {:ok, {:executed, %{phase: :planned}}} = run(fleet, "cleanup:discarded:plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:discarded:discard")

    assert %Placement{state: :retired} = retired = current_placement!(session)

    poll!(worker, @started)

    assert current_placement!(session) == retired
  end

  # Found live 2026-09-27 09:14 UTC, twelve minutes after the retirement above
  # shipped: a worker reported one more event for a session whose cleanup had
  # just retired its placement, the fleet refused it, and because a refused
  # batch refuses the whole poll and the worker re-sends it, every poll after
  # was refused and no Coop command reached the worker until the fix.
  test "a worker's late event for a retired placement is kept and acknowledged, never refusing the poll" do
    worker = enroll!("late-event")
    session = terminal_session!("late-event", worker)
    fleet = fleet_client(worker, @started, remote_session(session))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:late-event:grace")
    assert {:ok, {:executed, %{phase: :closed}}} = run(fleet, "cleanup:late-event:close")
    assert {:ok, {:executed, %{phase: :planned}}} = run(fleet, "cleanup:late-event:plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:late-event:discard")
    assert %Placement{state: :retired} = retired = current_placement!(session)

    batch = %{
      "after_sequence" => retired.last_acked_event_sequence,
      "events" => [
        %{
          "kind" => "session",
          "payload" => %{"state" => "discarded"},
          "sequence" => retired.last_acked_event_sequence + 1
        }
      ],
      "placement_generation" => retired.generation,
      "session_ref" => session.id
    }

    assert {:ok, %{"event_acknowledgements" => [acknowledged]}} =
             ControlPlane.handle_poll_certificate(
               worker,
               poll(worker, @started, event_batches: [batch])
             )

    assert acknowledged["sequence"] == retired.last_acked_event_sequence + 1

    # The same batch again, as a worker that lost the answer re-sends it.
    assert {:ok, %{"event_acknowledgements" => [_again]}} =
             ControlPlane.handle_poll_certificate(
               worker,
               poll(worker, @started, event_batches: [batch])
             )
  end

  # The same trap, one step later: the worker removed from Ryker can never
  # answer again, so waiting on it is waiting forever.
  test "a cleanup whose worker was removed from Ryker ends with a receipt instead of waiting" do
    worker = enroll!("removed")
    session = terminal_session!("removed", worker)
    assert {:ok, %{status: :revoked}} = WorkerLifecycle.revoke(worker, "operator:test")

    fleet = fleet_client(worker, @started, remote_session(session))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:removed:grace")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:removed:settle")

    settled = Repo.get!(Session, session.id)
    assert settled.cleanup_status == :discarded
    assert settled.cleanup_blocked_from == nil

    assert settled.cleanup_receipt == %{
             "kind" => "worker_removed",
             "local_session_id" => session.id,
             "remote_session_id" => session.coop_session_id,
             "remote_state" => "unreachable",
             "worker_id" => worker
           }

    assert commands(session) == []
  end

  # An outage is not a verdict about the session. The replacement refusal used
  # to be one: a worker away for a minute blocked cleanup for a person.
  test "a cleanup whose worker is away waits for it instead of blocking" do
    worker = enroll!("away")
    session = terminal_session!("away", worker)
    stop_reporting!(worker)
    expire_placements!(session)

    fleet = fleet_client(worker, @started, remote_session(session))

    assert {:ok, %{executed: 1}} = run_pass(fleet, "cleanup:away:grace")
    before = Repo.now!()
    assert {:ok, %{deferred: 1, blocked: 0}} = run_pass(fleet, "cleanup:away:outage")
    after_deferral = Repo.now!()

    waiting = Repo.get!(Session, session.id)
    assert waiting.cleanup_status == :close_pending
    assert waiting.cleanup_last_error_code == "retention_worker_unavailable"

    # The gate on 2026-09-26 once found the returned worker ignored here: the
    # deferral was stamped by the host clock and the worker's report by the
    # database clock, so a report a few milliseconds later could look older.
    # Both now come from the database clock.
    assert DateTime.compare(waiting.updated_at, before) != :lt
    assert DateTime.compare(waiting.updated_at, after_deferral) != :gt

    # The worker's own report is the evidence that brings the cleanup back.
    poll!(worker, @started)
    assert {:ok, %{executed: 1}} = run_pass(fleet, "cleanup:away:back")
    assert Repo.get!(Session, session.id).cleanup_status == :plan_pending
  end

  # Found live 2026-10-10: the fleet keeps a request on the placement it was
  # sent on, under its key, and answers "replacement required" for one whose
  # placement ended. A plan request cut off that way was asked again under the
  # same key on every retry, read that answer back, and took it for the worker
  # being away while the worker polled every few seconds: 392 times for one
  # session. Each such pass then skipped the worker, the cleanups due behind it
  # never ran, and a release failed its readiness check on the stalled queue.
  test "a cleanup request cut off by its placement's end is asked again on the worker's next one" do
    worker = enroll!("cut-off")
    session = terminal_session!("cut-off", worker)
    answer = remote_session(session)
    fleet = fleet_client(worker, @started, answer)

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:cut-off:grace")

    for {step, phase} <- [
          {"/close", :closed},
          {"/discard-plan", :planned},
          {"/discard", :discarded}
        ] do
      # The worker takes the request, and its placement ends before it answers.
      unanswered =
        fleet_client(worker, @started, fn command ->
          if String.ends_with?(command["payload"]["path"], step),
            do: :unanswered,
            else: answer.(command)
        end)

      assert {:ok, {:deferred, _timeout}} = run(unanswered, "cleanup:cut-off:#{step}:unanswered")
      expire_placements!(session)
      retry_due!(session)

      assert {:ok, {:executed, %{phase: ^phase}}} = run(fleet, "cleanup:cut-off:#{step}:back")
    end

    assert Repo.get!(Session, session.id).cleanup_status == :discarded
  end

  # A worker whose Coop no longer knows the session can be asked for nothing,
  # and its own 404 is the proof that nothing is left to close or remove.
  test "a session its worker no longer knows is recorded as already gone" do
    worker = enroll!("forgotten")
    session = terminal_session!("forgotten", worker)

    forgotten =
      fleet_client(worker, @started, fn _command ->
        {:error,
         %{"code" => "session_not_found", "detail" => "session not found", "status" => 404}}
      end)

    assert {:ok, {:executed, %{phase: :grace}}} = run(forgotten, "cleanup:forgotten:grace")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(forgotten, "cleanup:forgotten:settle")

    settled = Repo.get!(Session, session.id)
    assert settled.cleanup_status == :discarded

    assert settled.cleanup_receipt == %{
             "kind" => "remote_absent",
             "local_session_id" => session.id,
             "remote_session_id" => session.coop_session_id,
             "remote_state" => "absent"
           }
  end

  # In the 2026-10-11 Slack QA two delayed creates succeeded without binding
  # locally. Retiring a nil binding left a real native session on the worker;
  # this uses the real placement, command outbox and authenticated poll path.
  test "a proven unbound create is cleaned up only on its original holder" do
    worker = enroll!("unbound-create")
    {session, remote} = unbound_created_session!("unbound-create", worker)
    expire_placements!(session)
    fleet = fleet_client(worker, @started, remote_session(remote))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:unbound-create:bind")
    assert Repo.get!(Session, session.id).coop_session_id == remote.coop_session_id
    assert {:ok, {:executed, %{phase: :closed}}} = run(fleet, "cleanup:unbound-create:close")
    assert {:ok, {:executed, %{phase: :planned}}} = run(fleet, "cleanup:unbound-create:plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:unbound-create:discard")

    assert Repo.get!(Session, session.id).cleanup_receipt["kind"] == "discarded"
    assert current_placement!(session).worker_id == worker
    assert commands(session) == ~w(create_session reconcile_operation get_session close_session
             get_session plan_discard get_session discard_session)
  end

  test "unbound recovery refuses crossed creation provenance before binding" do
    worker = enroll!("crossed-provenance")
    {session, remote} = unbound_created_session!("crossed-provenance", worker)

    create =
      Repo.one!(
        from(c in Command, where: c.session_id == ^session.id and c.kind == "create_session")
      )

    assert {:ok, {:created, _, id}} = Creation.resolve(session)
    assert id == remote.coop_session_id

    create
    |> Ecto.Changeset.change(payload_fingerprint: String.duplicate("f", 64))
    |> Repo.update!()

    assert Creation.resolve(session) == {:error, :retention_creation_provenance_mismatch}

    Repo.get!(Command, create.id)
    |> Ecto.Changeset.change(payload_fingerprint: create.payload_fingerprint)
    |> Repo.update!()

    for payload <- [
          Map.put(create.payload, "job_digest", String.duplicate("e", 64)),
          Map.put(create.payload, "external_ref", "other-external-ref")
        ] do
      fingerprint =
        Ryker.CanonicalJSON.digest(%{
          "idempotency_key" => create.idempotency_key,
          "kind" => create.kind,
          "payload" => payload,
          "placement_id" => create.placement_id,
          "version" => create.command_version
        })

      Repo.get!(Command, create.id)
      |> Ecto.Changeset.change(payload: payload, payload_fingerprint: fingerprint)
      |> Repo.update!()

      assert Creation.resolve(session) == {:error, :retention_creation_provenance_mismatch}
    end

    Repo.get!(Command, create.id)
    |> Ecto.Changeset.change(
      payload: create.payload,
      payload_fingerprint: create.payload_fingerprint
    )
    |> Repo.update!()

    for operation <- [
          %{"id" => "op_other", "method" => "CreateRemoteSession", "state" => "running"},
          %{
            "id" => "op_created_crossed-provenance",
            "method" => "CloseSession",
            "state" => "running"
          }
        ] do
      Repo.get!(Command, create.id)
      |> Ecto.Changeset.change(result: %{"status" => 200, "body" => %{"operation" => operation}})
      |> Repo.update!()

      assert {:pending, _} = Creation.resolve(session)
      assert Repo.get!(Session, session.id).coop_session_id == nil
    end
  end

  test "an unknown never-bound receipt is reconsidered when its retained create proves a resource" do
    worker = enroll!("false-absence")
    {session, remote} = unbound_created_session!("false-absence", worker)

    receipt = %{
      "kind" => "never_bound",
      "local_session_id" => session.id,
      "remote_session_id" => nil,
      "remote_state" => "unknown"
    }

    session
    |> Ecto.Changeset.change(
      cleanup_status: :discarded,
      cleanup_receipt: receipt,
      cleanup_receipt_fingerprint: Ryker.CanonicalJSON.digest(receipt),
      discarded_at: Repo.now!()
    )
    |> Repo.update!()

    expire_placements!(session)
    fleet = fleet_client(worker, @started, remote_session(remote))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:false-absence:recover")
    recovered = Repo.get!(Session, session.id)
    assert recovered.coop_session_id == remote.coop_session_id
    assert is_nil(recovered.discarded_at)
    assert recovered.cleanup_receipt == receipt
    assert Enum.take(commands(session), 2) == ~w(create_session reconcile_operation)
  end

  test "an unresolved create is reconciled on its expired original holder without workspace work" do
    worker = enroll!("pending-create")
    {session, remote} = unbound_created_session!("pending-create", worker, false)
    expire_placements!(session)
    answer = remote_session(remote)

    fleet =
      fleet_client(worker, @started, fn command ->
        request = command["payload"]

        if String.starts_with?(request["path"], "/v1/operations?") do
          assert request["method"] == "GET"
          assert request["path"] =~ URI.encode_www_form("ryker:work:create:#{session.id}:g1")

          {:ok,
           operation(
             "op_created_pending-create",
             "CreateRemoteSession",
             "session",
             remote.coop_session_id
           )}
        else
          answer.(command)
        end
      end)

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:pending-create:bind")
    assert Repo.get!(Session, session.id).coop_session_id == remote.coop_session_id
    assert current_placement!(session).worker_id == worker
    assert commands(session) == ~w(create_session reconcile_operation)
  end

  test "a historical unbound create can be reconciled without repinning its vanished job" do
    worker = enroll!("historical-pending")
    {session, remote} = unbound_created_session!("historical-pending", worker, false)

    session
    |> Ecto.Changeset.change(worker_job_document: nil, worker_job_digest: nil)
    |> Repo.update!()

    fleet =
      fleet_client(worker, @started, fn command ->
        request = command["payload"]
        assert request["method"] == "GET"
        assert String.starts_with?(request["path"], "/v1/operations?")

        {:ok,
         operation(
           "op_created_historical-pending",
           "CreateRemoteSession",
           "session",
           remote.coop_session_id
         )}
      end)

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:historical-pending")
    assert Repo.get!(Session, session.id).coop_session_id == remote.coop_session_id
    assert Repo.get!(Session, session.id).worker_job_document == nil
    assert current_placement!(session).requirements["purpose"] == "stop_or_cleanup"
    assert commands(session) == ~w(create_session reconcile_operation)
    placement = current_placement!(session)

    assert ControlPlane.enqueue_command(
             placement.id,
             "prepare_session",
             %{"coop_session_id" => remote.coop_session_id, "expected_revision" => 7},
             "forbidden:historical-prepare:#{session.id}"
           ) == {:error, :coop_cleanup_only_placement}
  end

  test "a recovered create's exact holder can prove that its remote session is already absent" do
    worker = enroll!("recovered-absent")
    {session, remote} = unbound_created_session!("recovered-absent", worker)

    session
    |> Ecto.Changeset.change(discard_after: Repo.now!(), close_expected_revision: 7)
    |> Repo.update!()

    expire_placements!(session)

    fleet =
      fleet_client(worker, @started, fn _command ->
        {:error, %{"code" => "session_not_found", "status" => 404}}
      end)

    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:recovered-absent")

    assert Repo.get!(Session, session.id).cleanup_receipt["remote_session_id"] ==
             remote.coop_session_id

    assert Repo.get!(Session, session.id).cleanup_receipt["kind"] == "remote_absent"
  end

  test "a client-generated never-delivered fence proves absence without a worker request" do
    worker = enroll!("local-fence")
    session = terminal_session!("local-fence", worker)
    session = session |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update!()

    fleet =
      fleet_client(worker, @started, fn _ -> flunk("a local fence must not call the worker") end)

    key = "ryker:work:create:#{session.id}:g1"

    assert {:ok, %{"state" => "failed"}} =
             Client.fence_create_session(fleet, key, @policy, Session.coop_task_ref(session), nil)

    assert Creation.resolve(Repo.get!(Session, session.id)) == {:ok, :absent}
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:local-fence")
    assert commands(session) == ["create_session"]
    assert Repo.get!(Session, session.id).cleanup_receipt["remote_state"] == "absent"
  end

  test "a create-key lookup failure does not prove the remote resource absent" do
    worker = enroll!("lookup-absent")
    {session, _remote} = unbound_created_session!("lookup-absent", worker, false)

    fleet =
      fleet_client(worker, @started, fn _ ->
        # Exact Coop GET /v1/operations?key wire error (sessionsvc/http_test.go).
        {:error, %{"code" => "operation_not_found", "status" => 404}}
      end)

    assert run(fleet, "cleanup:lookup-absent") ==
             {:ok, {:deferred, :retention_creation_unresolved}}

    held = Repo.get!(Session, session.id)
    assert held.cleanup_status == :close_pending
    assert held.cleanup_receipt == nil
    assert held.coop_session_id == nil
  end

  test "a host rejection cannot override a proven successful remote create" do
    worker = enroll!("contradictory-rejection")
    {session, remote} = unbound_created_session!("contradictory-rejection", worker)

    create =
      Repo.one!(
        from(c in Command, where: c.session_id == ^session.id and c.kind == "create_session")
      )

    create
    |> Ecto.Changeset.change(
      status: :failed,
      delivered_at: nil,
      result: nil,
      error: %{"code" => "invalid_command"}
    )
    |> Repo.update!()

    assert {:ok, {:created, command, remote_id}} =
             Creation.resolve(Repo.get!(Session, session.id))

    assert command.id == create.id
    assert remote_id == remote.coop_session_id
  end

  test "creation evidence cannot bind after its cleanup lease is lost" do
    worker = enroll!("lost-recovery-lease")
    {session, _remote} = unbound_created_session!("lost-recovery-lease", worker)
    assert {:ok, claim} = Custody.claim_next("cleanup:lost-recovery-lease", 60)

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [cleanup_lease_expires_at: DateTime.add(Repo.now!(), -1, :second)]
    )

    assert Custody.recover_creation(session.id, claim.lease_ref) ==
             {:error, :retention_lease_lost}

    assert Repo.get!(Session, session.id).coop_session_id == nil
    assert Repo.get!(Session, session.id).cleanup_receipt == nil
  end

  test "a truncated creation journal never establishes a unique resource" do
    worker = enroll!("bounded-journal")
    {session, _remote} = unbound_created_session!("bounded-journal", worker)

    reconciliation =
      Repo.one!(
        from(c in Command, where: c.session_id == ^session.id and c.kind == "reconcile_operation")
      )

    for index <- 1..100 do
      key = "read:bounded-journal:#{index}:#{session.id}"
      copy = %{reconciliation | id: Ecto.UUID.generate(), idempotency_key: key}

      fingerprint =
        Ryker.CanonicalJSON.digest(%{
          "idempotency_key" => key,
          "kind" => copy.kind,
          "payload" => copy.payload,
          "placement_id" => copy.placement_id,
          "version" => copy.command_version
        })

      Repo.insert!(%{copy | payload_fingerprint: fingerprint})
    end

    assert Creation.resolve(Repo.get!(Session, session.id)) ==
             {:error, :retention_creation_ambiguous}

    assert Repo.get!(Session, session.id).coop_session_id == nil
  end

  # A healthy holder can keep one create unresolved while answering every other
  # cleanup. Treating that identity uncertainty as a worker outage skipped all
  # its siblings for the pass, needlessly holding their runtime/workspace slots.
  test "an unresolved create does not prevent healthy sibling cleanup in the same pass" do
    worker = enroll!("unresolved-sibling")
    {pending, _remote} = unbound_created_session!("unresolved-sibling", worker, false)
    sibling = terminal_session!("healthy-sibling", worker)
    answer = remote_session(sibling)

    fleet =
      fleet_client(worker, @started, fn command ->
        if String.starts_with?(command["payload"]["path"], "/v1/operations?") do
          {:ok,
           %{
             "id" => "op_created_unresolved-sibling",
             "method" => "CreateRemoteSession",
             "state" => "running"
           }}
        else
          answer.(command)
        end
      end)

    assert {:ok, %{attempted: 2, deferred: 1, executed: 1}} =
             run_pass(fleet, "cleanup:unresolved-sibling")

    assert Repo.get!(Session, pending.id).cleanup_status == :close_pending
    assert Repo.get!(Session, pending.id).coop_session_id == nil
    assert %DateTime{} = Repo.get!(Session, sibling.id).discard_after
  end

  test "a placed create that never left Ryker can settle without inventing a remote resource" do
    worker = enroll!("queued-create")
    {session, _remote} = unbound_created_session!("queued-create", worker, :queued)

    fleet =
      fleet_client(worker, @started, fn command ->
        assert command["payload"]["method"] == "GET"
        {:error, %{"code" => "operation_not_found", "status" => 404}}
      end)

    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:queued-create")
    assert Repo.get!(Session, session.id).coop_session_id == nil
    assert Repo.get!(Session, session.id).cleanup_receipt["remote_state"] == "absent"

    create =
      Repo.one!(
        from(c in Command, where: c.session_id == ^session.id and c.kind == "create_session")
      )

    assert create.delivered_at == nil
    assert create.error["code"] == "operation_not_enqueued"

    refute Enum.any?(
             commands(session),
             &(&1 in ~w(prepare_session submit_turn close_session discard_session))
           )
  end

  defp run(fleet, worker_ref) do
    Dispatcher.run_once(
      api: Client,
      client: fleet,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    )
  end

  defp run_pass(fleet, worker_ref) do
    Dispatcher.run_pass(
      api: Client,
      batch_limit: 25,
      batch_seconds: 30,
      client: fleet,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    )
  end

  # The bridge waits on the durable command row; each wait is one worker poll
  # that takes the queued commands and returns what the worker's Coop answered.
  defp fleet_client(worker, digest, answer) do
    assert {:ok, client} =
             Client.new(
               capability_names: ["controller-tools"],
               lease_seconds: 60,
               max_waits: 3,
               poll_interval_ms: 1,
               wait: fn -> serve(worker, digest, answer) end,
               workspace_ref: @workspace
             )

    client
  end

  defp serve(worker, digest, answer) do
    assert {:ok, %{"commands" => commands}} =
             ControlPlane.handle_poll_certificate(worker, poll(worker, digest))

    results =
      Enum.flat_map(commands, fn command ->
        case answer.(command) do
          # The worker took the command and never answered it.
          :unanswered ->
            []

          {:ok, resource} ->
            [
              %{
                "command_id" => command["command_id"],
                "error" => nil,
                "operation_key" => command["idempotency_key"],
                "resource" => %{"status" => 200, "body" => resource},
                "state" => "succeeded"
              }
            ]

          {:error, error} ->
            [
              %{
                "command_id" => command["command_id"],
                "error" => nil,
                "operation_key" => command["idempotency_key"],
                "resource" => %{
                  "status" => error["status"],
                  "body" => %{"error" => Map.drop(error, ["status"])}
                },
                "state" => "succeeded"
              }
            ]
        end
      end)

    if results != [] do
      assert {:ok, _response} =
               ControlPlane.handle_poll_certificate(
                 worker,
                 poll(worker, digest, command_results: results)
               )
    end

    :ok
  end

  # What the worker's Coop answers for the one session it holds: the version
  # the session was created under, whatever the worker runs now.
  defp remote_session(session) do
    document = fn state, revision ->
      remote = %{
        "authority_digest" => @authority,
        "external_ref" => session.external_ref,
        "id" => session.coop_session_id,
        "policy" => session.policy,
        "policy_digest" => session.policy_digest,
        "revision" => revision,
        "state" => state
      }

      if session.worker_job_document,
        do: Map.merge(remote, WorkerJob.receipt(session)),
        else: remote
    end

    fn command ->
      remote_id = session.coop_session_id
      path = "/v1/sessions/#{remote_id}"
      assert command["kind"] == "api_request"
      request = command["payload"]

      case {{request["method"], request["path"]},
            Repo.get_by!(Session, id: session.id).cleanup_status} do
        {{"GET", ^path}, :close_pending} ->
          {:ok, document.("open", 7)}

        {{"POST", close}, _status} when close == path <> "/close" ->
          {:ok,
           %{
             "operation" => operation("op_close", "CloseSession", "session", remote_id),
             "session" => document.("closed", 8)
           }}

        {{"GET", ^path}, :plan_pending} ->
          {:ok, document.("closed", 8)}

        {{"POST", plan}, _status} when plan == path <> "/discard-plan" ->
          {:ok,
           %{
             "operation" => operation("op_plan", "PlanDiscard", "discard_plan", remote_id),
             "plan" => %{
               "operation_id" => "op_plan",
               "plan" => %{
                 "revision" => 8,
                 "session_id" => remote_id,
                 "workspace" => %{
                   "accepted_dirty" => false,
                   "accepted_unmerged" => false,
                   "branch" => "coop/session",
                   "dirty" => false,
                   "head" => String.duplicate("a", 40),
                   "running" => false,
                   "status_digest" => String.duplicate("b", 64),
                   "unmerged" => false
                 }
               }
             }
           }}

        {{"GET", ^path}, :discard_pending} ->
          {:ok, document.("closed", 8)}

        {{"POST", discard}, _status} when discard == path <> "/discard" ->
          {:ok,
           %{
             "operation" => operation("op_discard", "Discard", "session", remote_id),
             "session" => document.("discarded", 9)
           }}
      end
    end
  end

  defp operation(id, method, resource_type, resource_id) do
    %{
      "id" => id,
      "method" => method,
      "resource_id" => resource_id,
      "resource_type" => resource_type,
      "state" => "succeeded"
    }
  end

  defp enroll!(suffix) do
    worker = "retention-#{suffix}-#{System.unique_integer([:positive])}"
    certificate = digest(worker)
    assert {:ok, _worker} = CoopWorkers.authorize(worker, @workspace, certificate)
    poll!(worker, @started)
    worker
  end

  defp poll!(worker, digest) do
    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker, poll(worker, digest))
  end

  defp poll(worker, digest, options \\ []) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => Keyword.get(options, :command_results, []),
      "event_batches" => Keyword.get(options, :event_batches, []),
      "poll_ref" => "poll:#{worker}:#{System.unique_integer([:positive])}",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-worker-change",
        "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 2,
          "session_slots_total" => 2,
          "state" => "eligible",
          "turn_slots_free" => 2,
          "turn_slots_total" => 2,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 2
        },
        "clock_at" => DateTime.to_iso8601(Ryker.Repo.now!()),
        "id" => worker,
        "protocol_version" => "2",
        "sandbox_digest" => digest,
        "state" => "eligible",
        "workspace_ref" => @workspace
      }
    }
  end

  # A finished conversation's session, created on this worker under @started.
  defp terminal_session!(suffix, worker) do
    id = Ecto.UUID.generate()
    key = "retention-worker-change:#{suffix}:#{id}"
    turn_ref = "turn:#{suffix}:#{id}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "source:#{suffix}:#{id}",
                 occurred_at: Ryker.Repo.now!(),
                 turn_ref: turn_ref
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(id, @policy, @started, authority_digest: @authority)

    session = WorkerJob.pin!(session)

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: nil,
                 workspace_ref: @workspace
               },
               60
             )

    assert placement.worker_id == worker

    session =
      session
      |> Ecto.Changeset.change(
        coop_session_id: "remote_#{suffix}_#{String.replace(id, "-", "")}",
        worker_job_document: nil,
        worker_job_digest: nil
      )
      |> Repo.update!()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{suffix}:#{id}",
                 episode_key: key,
                 expected_owner: %{kind: :turn, ref: turn_ref},
                 occurred_at: Ryker.Repo.now!()
               })
             )

    session
  end

  defp unbound_created_session!(suffix, worker, reconciled? \\ true) do
    bound = terminal_session!(suffix, worker)

    session =
      bound |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update!() |> WorkerJob.pin!()

    placement = current_placement!(session)
    key = "ryker:work:create:#{session.id}:g1"
    operation_id = "op_created_#{suffix}"

    assert {:ok, _create} =
             ControlPlane.enqueue_command(
               placement.id,
               "create_session",
               %{
                 "external_ref" => session.external_ref,
                 "job" => session.worker_job_document,
                 "job_digest" => session.worker_job_digest
               },
               key
             )

    if reconciled? != :queued do
      serve(worker, @started, fn _command ->
        {:ok,
         %{
           "operation" => %{
             "id" => operation_id,
             "method" => "CreateRemoteSession",
             "state" => "running"
           }
         }}
      end)
    end

    if reconciled? == true do
      assert {:ok, _reconcile} =
               ControlPlane.enqueue_command(
                 placement.id,
                 "reconcile_operation",
                 %{"operation_key" => key},
                 Command.read_key("reconcile_operation")
               )

      serve(worker, @started, fn _command ->
        {:ok, operation(operation_id, "CreateRemoteSession", "session", bound.coop_session_id)}
      end)
    end

    {session, %{session | coop_session_id: bound.coop_session_id}}
  end

  # The placement lease ran out while nothing addressed the session.
  defp expire_placements!(session) do
    Repo.update_all(
      from(placement in Placement, where: placement.session_id == ^session.id),
      set: [lease_expires_at: DateTime.add(Ryker.Repo.now!(), -1, :second)]
    )
  end

  defp retry_due!(session) do
    Repo.update_all(from(value in Session, where: value.id == ^session.id),
      set: [cleanup_next_attempt_at: DateTime.add(Ryker.Repo.now!(), -1, :second)]
    )
  end

  defp stop_reporting!(worker) do
    {1, nil} =
      Repo.update_all(from(value in Worker, where: value.id == ^worker),
        set: [last_seen_at: DateTime.add(Ryker.Repo.now!(), -600, :second)]
      )
  end

  defp commands(session) do
    Repo.all(
      from(command in Command,
        where: command.session_id == ^session.id,
        order_by: [asc: command.inserted_at, asc: command.id],
        select: command.kind
      )
    )
  end

  defp current_placement!(session) do
    Repo.one!(
      from(placement in Placement,
        where: placement.session_id == ^session.id,
        order_by: [desc: placement.generation],
        limit: 1
      )
    )
  end
end
