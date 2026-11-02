defmodule Ryker.Retention.CustodyTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.{Command, ControlPlane}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Operator.Retention, as: RetentionOperator
  alias Ryker.Operator.RetentionAction
  alias Ryker.Retention.{Custody, Plan}
  alias Ryker.Work.Session

  @now ~U[2026-08-29 10:00:00.000000Z]

  # A stopped weekly review was reported eligible for hours but skipped by
  # the locked check forever, keeping readiness red and upgrades failing.
  test "weekly review cleanup waits for remote stop proof and then claims its session" do
    review =
      Repo.insert!(%Ryker.WeeklyReport.Review{
        identity: String.duplicate("e", 64),
        conversation_ref: "weekly-retention",
        period_start: @now,
        period_end: DateTime.add(@now, 604_800),
        deadline_at: DateTime.add(@now, 605_100),
        timezone: "Etc/UTC",
        status: :rejected,
        policy: "weekly-review",
        policy_digest: String.duplicate("a", 64),
        prompt_sha256: String.duplicate("b", 64)
      })

    session =
      Repo.insert!(%Session{
        execution_kind: :weekly_review,
        weekly_review_id: review.id,
        policy: "weekly-review",
        policy_digest: String.duplicate("a", 64),
        external_ref: "session:weekly-retention",
        coop_session_id: "remote-weekly-retention"
      })

    assert Custody.claim_next("cleanup:weekly", 60) == {:ok, nil}

    review
    |> Ecto.Changeset.change(
      remote_stopped_at: Repo.now!(),
      stop_receipt: %{"kind" => "terminal_turn"}
    )
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("cleanup:weekly", 60)
    assert claim.session.id == session.id
    assert claim.session.cleanup_status == :close_pending
    assert claim.owner.id == review.id
  end

  # One waiting session held sixteen full companion histories for days. Closing
  # idle execution must release those copies without erasing the conversation.
  test "a settled read-only wait closes after grace and retains its primary until replaced" do
    {session, _turn} = waiting_session!("idle-read-only")
    assert {:ok, %{session: _} = claim} = Custody.claim_next("cleanup:idle", 60)
    assert claim.session.id == session.id
    assert {:ok, _grace} = Custody.begin_grace(session.id, claim.lease_ref, 0)
    assert {:ok, close} = Custody.claim_next("cleanup:idle-close", 60)
    assert {:ok, closed} = Custody.mark_closed(session.id, close.lease_ref)
    assert closed.closed_at
    assert closed.cleanup_status == :plan_pending
    assert Custody.claim_next("cleanup:keep-primary", 60) == {:ok, nil}

    assert {:ok, resumed} =
             WorkSessions.pin_episode(session.episode_id, session.policy, session.policy_digest)

    assert resumed.generation == session.generation + 1
    assert resumed.cleanup_status == :active
    assert resumed.closed_at == nil
    assert {:ok, old} = Custody.claim_next("cleanup:replaced-wait", 60)
    assert old.session.id == session.id
  end

  test "waiting cleanup requires the latest accepted turn and durable read-only authority" do
    for reason <- [
          :unaccepted,
          :blocked,
          :superseded,
          :queued_input,
          :unproven_job,
          :writable_job
        ] do
      {session, turn} = waiting_session!("idle-#{reason}")

      case reason do
        :unaccepted ->
          Repo.update!(
            Ecto.Changeset.change(turn,
              status: :blocked,
              accepted_at: nil,
              validation_intent: nil,
              validation_intent_fingerprint: nil,
              validation_receipt: nil,
              result_ref: nil,
              continuation: nil
            )
          )

        status when status in [:blocked, :superseded] ->
          Repo.update!(Ecto.Changeset.change(turn, status: status))

        :queued_input ->
          episode = Repo.get!(Episodes.Episode, session.episode_id)

          Repo.update!(
            Ecto.Changeset.change(episode,
              queued_input_refs: ["input:queued"],
              queued_input_order_keys: ["1"]
            )
          )

        :unproven_job ->
          Repo.update!(
            Ecto.Changeset.change(session, worker_job_digest: String.duplicate("0", 64))
          )

        :writable_job ->
          job = Map.put(session.worker_job_document, "repository_read_only", false)

          Repo.update!(
            Ecto.Changeset.change(session,
              worker_job_document: job,
              worker_job_digest: CanonicalJSON.worker_digest(job)
            )
          )
      end

      assert Custody.claim_next("cleanup:unsafe-wait", 60) == {:ok, nil}, "claimed #{reason}"
      assert Custody.eligible_copies(Repo.now!(), 10) == {[], 0}
    end
  end

  # Twenty-five rejected candidates used to exhaust every poll's pass-over
  # budget and make readiness red while valid cleanup behind them never ran.
  test "protected waits cannot starve later cleanup or inflate readiness backlog" do
    for index <- 1..25 do
      {session, _turn} = waiting_session!("protected-prefix-#{index}")
      Repo.update!(Ecto.Changeset.change(session, worker_job_digest: String.duplicate("0", 64)))
    end

    assert Custody.eligible_copies(Repo.now!(), 10) == {[], 0}
    assert {:ok, queues} = Ryker.Observability.Queues.snapshot(Repo.now!())
    assert Enum.find(queues, &(&1.name == :retention)).claimable == 0
    terminal = terminal_session!("after-protected-waits")
    assert {:ok, %{session: claimed}} = Custody.claim_next("cleanup:after-protected", 60)
    assert claimed.id == terminal.id
  end

  test "a newer blocked turn prevents closing an older accepted wait" do
    {session, turn} = waiting_session!("latest-blocked")

    Repo.insert!(%Ryker.Work.Turn{
      episode_id: session.episode_id,
      session_id: session.id,
      turn_ref: "turn:newer-blocked",
      status: :blocked,
      inserted_at: DateTime.add(turn.inserted_at, 1)
    })

    assert Custody.claim_next("cleanup:newer-blocked", 60) == {:ok, nil}
  end

  test "a waiting session resumes in grace and queued input fences an in-flight close" do
    {session, _turn} = waiting_session!("wait-grace")
    assert {:ok, %{session: _} = claim} = Custody.claim_next("cleanup:wait-grace", 60)
    episode = Repo.get!(Episodes.Episode, session.episode_id)

    episode =
      Repo.update!(
        Ecto.Changeset.change(episode,
          queued_input_refs: ["input:queued"],
          queued_input_order_keys: ["1"]
        )
      )

    assert Custody.mark_closed(session.id, claim.lease_ref) == {:error, :retention_lease_lost}

    Repo.update!(
      Ecto.Changeset.change(episode, queued_input_refs: [], queued_input_order_keys: [])
    )

    assert {:ok, _grace} = Custody.begin_grace(session.id, claim.lease_ref, 900)

    assert {:ok, resumed} =
             WorkSessions.pin_episode(session.episode_id, session.policy, session.policy_digest)

    assert resumed.id == session.id
    assert resumed.cleanup_status == :active
  end

  test "a writable wait requires the exact latest candidate checkpoint and its retained body" do
    root = Path.join(System.tmp_dir!(), "ryker-wait-checkpoint-#{Ecto.UUID.generate()}")
    previous = System.get_env("RYKER_STATE_DIR")
    System.put_env("RYKER_STATE_DIR", root)

    on_exit(fn ->
      if previous,
        do: System.put_env("RYKER_STATE_DIR", previous),
        else: System.delete_env("RYKER_STATE_DIR")

      File.rm_rf!(root)
    end)

    {session, turn} = waiting_session!("writable-checkpoint")
    job = Map.put(session.worker_job_document, "repository_read_only", false)

    session =
      Repo.update!(
        Ecto.Changeset.change(session,
          worker_job_document: job,
          worker_job_digest: CanonicalJSON.worker_digest(job),
          workspace_task: %{"offer_ref" => "task:waiting-checkpoint"}
        )
      )

    assert Custody.claim_next("cleanup:no-checkpoint", 60) == {:ok, nil}
    unbound = Repo.update!(Ecto.Changeset.change(session, coop_session_id: nil))
    create = create_command!(unbound, "writable-checkpoint")
    Repo.update!(Ecto.Changeset.change(unbound, coop_session_id: session.coop_session_id))
    # Retry generation is part of the checkpoint identity, just like the candidate.
    turn = Repo.update!(Ecto.Changeset.change(turn, checkpoint_retry_generation: 2))

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               create.placement_id,
               "checkpoint_workspace",
               %{},
               Ryker.Work.OperationKeys.checkpoint(turn)
             )

    command =
      Repo.update!(
        Ecto.Changeset.change(command,
          status: :succeeded,
          result: %{"status" => 200},
          completed_at: Repo.now!(),
          result_fingerprint: String.duplicate("a", 64)
        )
      )

    bundle = :binary.copy(<<3>>, 4096)
    reference = %{"sha256" => Ryker.Crypto.sha256_hex(bundle), "byte_size" => byte_size(bundle)}
    key = Ryker.Secret.new(:binary.copy(<<9>>, 32))

    transfer =
      Repo.insert!(%Ryker.CoopFleet.WorkspaceCheckpointTransfer{
        command_id: command.id,
        body_command_id: command.id,
        session_ref: session.id,
        repository_ref: session.repository_ref,
        checkpoint_ref: "checkpoint:waiting",
        worker_id: command.worker_id,
        placement_generation: command.placement_generation,
        descriptor: %{"version" => 2, "checkpoint_ref" => "checkpoint:waiting"},
        bundle_sha256: reference["sha256"],
        bundle_byte_size: reference["byte_size"],
        encryption_key_sha256: Ryker.Crypto.sha256_hex(Ryker.Secret.reveal(key))
      })

    assert Custody.claim_next("cleanup:missing-body", 60) == {:ok, nil}
    assert Custody.eligible_copies(Repo.now!(), 10) == {[], 0}

    assert Ryker.CoopFleet.Bodies.put(
             Path.join(root, "worker-bodies"),
             command.id,
             :response,
             reference,
             [bundle],
             key
           ) == :ok

    transfer = Repo.update!(Ecto.Changeset.change(transfer, session_ref: Ecto.UUID.generate()))
    assert Custody.claim_next("cleanup:wrong-source", 60) == {:ok, nil}
    Repo.update!(Ecto.Changeset.change(transfer, session_ref: session.id))
    turn = Repo.update!(Ecto.Changeset.change(turn, checkpoint_retry_generation: 3))
    assert Custody.claim_next("cleanup:older-checkpoint", 60) == {:ok, nil}
    Repo.update!(Ecto.Changeset.change(turn, checkpoint_retry_generation: 2))
    assert {:ok, %{session: claimed}} = Custody.claim_next("cleanup:saved-checkpoint", 60)
    assert claimed.id == session.id
  end

  test "resuming between a waiting close request and its reply cannot close the successor" do
    {session, _turn} = waiting_session!("idle-close-race")
    assert {:ok, %{session: _} = claim} = Custody.claim_next("cleanup:idle-race", 60)
    episode = Repo.get!(Episodes.Episode, session.episode_id)

    Repo.update!(
      Ecto.Changeset.change(episode,
        state: :working,
        owner_kind: :turn,
        owner_ref: "turn:resumed"
      )
    )

    assert Custody.mark_closed(session.id, claim.lease_ref) == {:error, :retention_lease_lost}

    assert {:ok, successor} =
             WorkSessions.pin_episode(session.episode_id, session.policy, session.policy_digest)

    assert successor.id != session.id
    assert {:ok, closed} = Custody.mark_closed(session.id, claim.lease_ref)
    assert closed.closed_at
    assert Repo.get!(Session, successor.id).closed_at == nil
  end

  test "only one worker claims an exact terminal owned session" do
    active = session!("active")
    terminal = terminal_session!("terminal")

    assert {:ok, claim} = Ryker.Retention.Custody.claim_next("cleanup:a", 60)
    assert claim.session.id == terminal.id
    assert claim.session.cleanup_status == :close_pending
    assert claim.session.cleanup_attempt_count == 1
    assert is_binary(claim.lease_ref)
    assert Ryker.Retention.Custody.claim_next("cleanup:b", 60) == {:ok, nil}

    assert Repo.get!(Session, active.id).cleanup_status == :active
  end

  # A replaced Work session stayed open on its worker, holding its workspace,
  # until the episode ended, however long the episode then waited
  # (2026-10-04 review).
  test "a replaced Work session is cleaned up while its episode keeps working" do
    replaced = session!("replaced-generation")
    assert {:ok, claim} = Ryker.Work.Custody.claim_next("work:replaced-generation", 60, :work)

    assert {:ok, %{session: current}} =
             Ryker.Work.Custody.rotate_session(
               replaced.episode_id,
               claim.turn.turn_ref,
               claim.lease_ref,
               replaced.generation
             )

    assert current.generation == replaced.generation + 1

    assert {:ok, cleanup} = Ryker.Retention.Custody.claim_next("cleanup:replaced", 60)
    assert cleanup.session.id == replaced.id
    assert Ryker.Retention.Custody.claim_next("cleanup:current", 60) == {:ok, nil}
    assert Repo.get!(Session, current.id).cleanup_status == :active
  end

  test "a restarted cleanup host releases the leases it can no longer own" do
    # After a restart the host still appeared to hold its own cleanup leases, so
    # every claimed item waited out the full lease clock before anyone retried it.
    mine = terminal_session!("restart-mine")
    theirs = terminal_session!("restart-theirs")

    assert {:ok, first} = Custody.claim_next("cleanup:host-a", 3_600)
    assert {:ok, second} = Custody.claim_next("cleanup:host-b", 3_600)
    claimed = MapSet.new([first.session.id, second.session.id])
    assert claimed == MapSet.new([mine.id, theirs.id])

    {mine, theirs} =
      if first.session.cleanup_lease_owner == "cleanup:host-a",
        do: {first.session, second.session},
        else: {second.session, first.session}

    assert Custody.release_worker_leases("cleanup:host-a") == {:ok, 1}

    released = Repo.get!(Session, mine.id)
    assert is_nil(released.cleanup_lease_ref)
    assert is_nil(released.cleanup_lease_owner)
    assert is_nil(released.cleanup_lease_expires_at)
    assert released.cleanup_status == :close_pending

    held = Repo.get!(Session, theirs.id)
    assert held.cleanup_lease_owner == "cleanup:host-b"

    assert {:ok, reclaimed} = Custody.claim_next("cleanup:host-a", 60)
    assert reclaimed.session.id == mine.id

    assert Custody.release_worker_leases(<<0>>) ==
             {:error, {:invalid_retention_custody, :worker_ref}}
  end

  test "close and discard phases freeze exact revisions and survive lease turnover" do
    session = terminal_session!("lifecycle")
    assert {:ok, grace_claim} = Ryker.Retention.Custody.claim_next("cleanup:grace", 60)

    assert {:ok, grace} = Custody.begin_grace(session.id, grace_claim.lease_ref, 0)
    assert grace.cleanup_status == :grace
    assert grace.cleanup_lease_ref == nil
    assert is_nil(grace.closed_at)
    assert %DateTime{} = grace.discard_after

    assert {:ok, claim} = Ryker.Retention.Custody.claim_next("cleanup:a", 60)
    assert claim.session.cleanup_status == :close_pending

    assert {:ok, frozen} =
             Custody.freeze_close_revision(session.id, claim.lease_ref, 7)

    assert frozen.close_expected_revision == 7

    assert {:ok, same_frozen} = Custody.freeze_close_revision(session.id, claim.lease_ref, 7)
    assert same_frozen.close_expected_revision == 7

    assert Custody.freeze_close_revision(session.id, claim.lease_ref, 8) ==
             {:error, {:retention_close_revision_conflict, 7}}

    assert Custody.advance_close(session.id, claim.lease_ref, 2) ==
             {:error, {:retention_generation_conflict, 1}}

    assert {:ok, advanced} = Custody.advance_close(session.id, claim.lease_ref, 1)
    assert advanced.close_generation == 2
    assert advanced.close_expected_revision == nil

    assert {:ok, refrozen} = Custody.freeze_close_revision(session.id, claim.lease_ref, 8)
    assert refrozen.close_expected_revision == 8

    assert Custody.freeze_close_revision(session.id, "stale", 8) ==
             {:error, :retention_lease_lost}

    assert {:ok, closed} = Custody.mark_closed(session.id, claim.lease_ref)

    assert closed.cleanup_status == :plan_pending
    assert closed.cleanup_lease_ref == nil
    assert %DateTime{} = closed.closed_at

    assert {:ok, plan_claim} =
             Custody.claim_next("cleanup:b", 60)

    assert plan_claim.session.id == session.id
    assert plan_claim.session.cleanup_status == :plan_pending

    assert {:ok, plan_frozen} =
             Custody.freeze_plan_revision(
               session.id,
               plan_claim.lease_ref,
               8,
               false
             )

    assert plan_frozen.discard_plan_expected_revision == 8
    refute plan_frozen.discard_plan_accept_unmerged

    assert {:ok, _same_plan} =
             Custody.freeze_plan_revision(session.id, plan_claim.lease_ref, 8, false)

    assert Custody.freeze_plan_revision(session.id, plan_claim.lease_ref, 8, true) ==
             {:error, {:retention_plan_revision_conflict, 8}}

    assert Custody.advance_plan(session.id, plan_claim.lease_ref, 2) ==
             {:error, {:retention_generation_conflict, 1}}

    plan = discard_plan(session.coop_session_id, 8, false, false)
    assert {:ok, prepared} = Plan.prepare(plan, session.coop_session_id, 8, false)

    assert {:ok, pending} =
             Custody.store_plan(session.id, plan_claim.lease_ref, prepared, 21_600)

    assert pending.cleanup_status == :discard_pending
    assert pending.discard_plan_operation_id == "op_plan"

    # A delayed refusal must not clear a replacement plan or another host's
    # lease. Both mutation generations are custody, not merely retry counters.
    assert Custody.invalidate_discard_plan(session.id, "stale", 1, 1) ==
             {:error, :retention_lease_lost}

    expire_cleanup_lease!(pending.id)

    assert Custody.invalidate_discard_plan(session.id, plan_claim.lease_ref, 1, 1) ==
             {:error, :retention_lease_lost}

    assert {:ok, discard_claim} =
             Custody.claim_next("cleanup:c", 60)

    for {plan_generation, discard_generation} <- [{2, 1}, {1, 2}] do
      assert Custody.invalidate_discard_plan(
               session.id,
               discard_claim.lease_ref,
               plan_generation,
               discard_generation
             ) ==
               {:error, :retention_discard_plan_generation_conflict}

      assert Repo.get!(Session, session.id).discard_plan == pending.discard_plan
      assert Repo.get!(Session, session.id).cleanup_status == :discard_pending
    end

    assert Custody.settle_discard(
             session.id,
             discard_claim.lease_ref,
             "ryker:retention:discard:#{session.id}:g1",
             "remote:wrong"
           ) == {:error, :retention_remote_session_mismatch}

    assert Custody.settle_discard(
             session.id,
             discard_claim.lease_ref,
             "wrong-operation",
             session.coop_session_id
           ) == {:error, :retention_discard_operation_mismatch}

    assert {:ok, discarded} =
             Custody.settle_discard(
               session.id,
               discard_claim.lease_ref,
               "ryker:retention:discard:#{session.id}:g1",
               session.coop_session_id
             )

    assert discarded.cleanup_status == :discarded
    assert discarded.cleanup_receipt["remote_session_id"] == session.coop_session_id
    assert discarded.cleanup_receipt["kind"] == "discarded"
    assert %DateTime{} = discarded.discarded_at
  end

  test "a terminal session that was never bound settles as an exact local absence" do
    session = terminal_session!("never-bound")
    session |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("cleanup:absent", 60)
    assert claim.session.id == session.id

    assert {:ok, settled} = Custody.settle_absent(session.id, claim.lease_ref)
    assert settled.cleanup_status == :discarded
    assert settled.cleanup_receipt["kind"] == "never_bound"
    assert settled.cleanup_receipt["remote_session_id"] == nil

    bound = terminal_session!("bound")
    assert {:ok, bound_claim} = Custody.claim_next("cleanup:bound", 60)
    assert bound_claim.session.id == bound.id

    assert Custody.settle_absent(bound.id, bound_claim.lease_ref) ==
             {:error, :retention_remote_session_bound}
  end

  # Two delayed creates succeeded during the 2026-10-11 Slack QA. One was
  # subsequently marked discarded with an unknown remote state, leaving the
  # real worker resource without cleanup custody after its run was replaced.
  test "an unbound session keeps cleanup custody while creation is unresolved" do
    session = terminal_session!("unresolved-create")
    session = session |> Ecto.Changeset.change(coop_session_id: nil) |> Repo.update!()
    command = create_command!(session, "unresolved-create")

    assert {:ok, claim} = Custody.claim_next("cleanup:unresolved-create", 60)
    assert claim.session.id == session.id

    assert Custody.settle_absent(session.id, claim.lease_ref) ==
             {:error, :retention_creation_unresolved}

    stored = Repo.get!(Session, session.id)
    assert stored.cleanup_status == :close_pending
    assert stored.cleanup_lease_ref == claim.lease_ref
    assert is_nil(stored.discarded_at)
    assert is_nil(stored.cleanup_receipt)
    assert Repo.get!(Command, command.id).status == :queued
  end

  test "invalid cleanup identities never enter a lease transaction" do
    assert Custody.claim_next("", 60) == {:error, {:invalid_retention_custody, :worker_ref}}

    assert Custody.claim_next("worker", 0) ==
             {:error, {:invalid_retention_custody, :lease_seconds}}

    assert Custody.freeze_close_revision("not-a-uuid", "lease", 1) ==
             {:error, {:invalid_retention_custody, :uuid}}

    assert Custody.freeze_close_revision(Ecto.UUID.generate(), "lease", 0) ==
             {:error, {:invalid_retention_custody, :revision}}

    assert Custody.store_plan(Ecto.UUID.generate(), "lease", nil, 21_600) ==
             {:error, {:invalid_retention_custody, :plan}}
  end

  test "dirty and unpublished unmerged plans are durably retained" do
    for {suffix, dirty, unmerged, reason} <- [
          {"dirty", true, false, "dirty"},
          {"unpublished", false, true, "unpublished_unmerged"}
        ] do
      session = terminal_session!(suffix)
      assert {:ok, _closed} = grace_and_close!(session, suffix)

      assert {:ok, plan_claim} =
               Ryker.Retention.Custody.claim_next("cleanup:plan:#{suffix}", 60)

      assert {:ok, _frozen} =
               Ryker.Retention.Custody.freeze_plan_revision(
                 session.id,
                 plan_claim.lease_ref,
                 8,
                 false
               )

      response = discard_plan(session.coop_session_id, 8, dirty, unmerged)
      assert {:ok, plan} = Plan.prepare(response, session.coop_session_id, 8, false)

      assert {:ok, retained} =
               Ryker.Retention.Custody.store_plan(
                 session.id,
                 plan_claim.lease_ref,
                 plan,
                 21_600
               )

      assert retained.cleanup_status == :retained
      assert retained.retained_reason == reason
      assert retained.cleanup_lease_ref == nil
    end
  end

  test "an operator rearms the exact blocked cleanup phase with an audited idempotency key" do
    session = terminal_session!("operator-rearm")
    assert {:ok, _closed} = grace_and_close!(session, "operator-rearm")
    assert {:ok, plan_claim} = Custody.claim_next("cleanup:plan", 60)

    assert {:ok, frozen} =
             Custody.freeze_plan_revision(session.id, plan_claim.lease_ref, 8, false)

    assert {:ok, blocked} =
             Custody.block(
               session.id,
               plan_claim.lease_ref,
               "coop_protocol_error",
               "the exact plan envelope was invalid"
             )

    assert blocked.cleanup_status == :blocked
    assert blocked.cleanup_blocked_from == :plan_pending
    assert blocked.discard_plan_expected_revision == frozen.discard_plan_expected_revision

    assert {:ok, %{action: rearm_action, outcome: :rearmed, session: rearmed}} =
             RetentionOperator.rearm(
               session.external_ref,
               "operator:local",
               "retention-action:rearm:one"
             )

    assert rearm_action.request_fingerprint ==
             CanonicalJSON.digest(%{
               "action" => "rearm",
               "actor_ref" => "operator:local",
               "session_ref" => session.external_ref
             })

    assert rearmed.cleanup_status == :plan_pending
    assert rearmed.cleanup_blocked_from == nil
    assert rearmed.cleanup_attempt_count == 0
    assert rearmed.cleanup_last_error_code == nil
    assert rearmed.discard_plan_expected_revision == 8

    assert {:ok, %{outcome: :duplicate}} =
             RetentionOperator.rearm(
               session.external_ref,
               "operator:local",
               "retention-action:rearm:one"
             )

    assert Repo.aggregate(Ryker.Operator.RetentionAction, :count) == 1

    assert RetentionOperator.discard_unmerged(
             session.external_ref,
             String.duplicate("a", 64),
             "operator:local",
             "retention-action:rearm:one"
           ) == {:error, :retention_operator_action_conflict}
  end

  # Cleanup custody ages a session from its last change by the database clock,
  # but an operator's rearm stamped that change with the host's clock, so a
  # host clock behind the database aged the rearmed step from before it was
  # rearmed (2026-10-04 review).
  test "an operator's rearm is stamped by the database clock" do
    session = terminal_session!("operator-clock")
    assert {:ok, _closed} = grace_and_close!(session, "operator-clock")
    assert {:ok, claim} = Custody.claim_next("cleanup:plan", 60)
    assert {:ok, _frozen} = Custody.freeze_plan_revision(session.id, claim.lease_ref, 8, false)

    assert {:ok, _blocked} =
             Custody.block(session.id, claim.lease_ref, "coop_protocol_error", "x")

    # Structural fixture: the database clock runs a day ahead of the host's.
    Repo.query!("CREATE SCHEMA ahead_clock")

    Repo.query!("""
    CREATE FUNCTION ahead_clock.clock_timestamp() RETURNS timestamptz LANGUAGE sql STABLE AS $$
      SELECT pg_catalog.clock_timestamp() + interval '1 day'
    $$
    """)

    Repo.query!("SET search_path TO ahead_clock, pg_catalog, public")

    assert {:ok, %{outcome: :rearmed, session: rearmed}} =
             RetentionOperator.rearm(
               session.external_ref,
               "operator:local",
               "retention-action:clock"
             )

    assert DateTime.diff(Repo.now!(), rearmed.updated_at, :second) in 0..60,
           "the rearm was stamped #{DateTime.diff(Repo.now!(), rearmed.updated_at, :second)} s behind the database clock"
  end

  test "explicit unmerged discard refreshes the exact plan while dirty work stays retained" do
    unmerged = retained_session!("operator-unmerged", false, true)
    dirty = retained_session!("operator-dirty", true, false)

    assert {:ok, %{action: discard_action, outcome: :discard_requested, session: replanning}} =
             RetentionOperator.discard_unmerged(
               unmerged.external_ref,
               unmerged.discard_plan_fingerprint,
               "operator:local",
               "retention-action:discard:unmerged"
             )

    assert discard_action.request_fingerprint ==
             CanonicalJSON.digest(%{
               "action" => "discard_unmerged",
               "actor_ref" => "operator:local",
               "expected_plan_fingerprint" => unmerged.discard_plan_fingerprint,
               "session_ref" => unmerged.external_ref
             })

    assert replanning.cleanup_status == :plan_pending
    assert replanning.discard_plan_accept_unmerged
    assert replanning.discard_plan_generation == unmerged.discard_plan_generation + 1
    assert replanning.discard_plan == nil
    assert replanning.discard_plan_fingerprint == nil
    assert replanning.retained_reason == nil

    assert {:ok, %{outcome: :duplicate}} =
             RetentionOperator.discard_unmerged(
               unmerged.external_ref,
               unmerged.discard_plan_fingerprint,
               "operator:local",
               "retention-action:discard:unmerged"
             )

    assert RetentionOperator.discard_unmerged(
             dirty.external_ref,
             dirty.discard_plan_fingerprint,
             "operator:local",
             "retention-action:discard:dirty"
           ) == {:error, :retention_dirty_workspace}

    assert Repo.get!(Session, dirty.id).cleanup_status == :retained
    assert Repo.get!(Session, dirty.id).retained_reason == "dirty"
  end

  test "concurrent retries of one operator action serialize before reading its ledger" do
    Sandbox.unboxed_run(Repo, fn ->
      session = retained_session!("operator-concurrent", false, true)
      parent = self()
      action_ref = "retention-action:discard:concurrent"

      blocker =
        Ryker.ConcurrencyCase.unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.one!(from(row in Session, where: row.id == ^session.id, lock: "FOR UPDATE"))
            send(parent, {:session_locked, Ryker.ConcurrencyCase.backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      task_key = {__MODULE__, :operator_action_tasks}
      Process.put(task_key, [blocker])

      try do
        assert_receive {:session_locked, blocker_backend}, 5_000

        first =
          operator_action_task(
            parent,
            session.external_ref,
            session.discard_plan_fingerprint,
            action_ref,
            :first
          )

        Process.put(task_key, [first | Process.get(task_key)])
        assert_receive {:operator_started, :first, first_backend}, 5_000
        Ryker.ConcurrencyCase.await_blocked_by(first_backend, blocker_backend)

        second =
          operator_action_task(
            parent,
            session.external_ref,
            session.discard_plan_fingerprint,
            action_ref,
            :second
          )

        Process.put(task_key, [second | Process.get(task_key)])
        assert_receive {:operator_started, :second, second_backend}, 5_000
        Ryker.ConcurrencyCase.await_blocked_by(second_backend, first_backend)

        send(blocker.pid, :release)
        assert {:ok, _transaction} = Task.await(blocker, 5_000)

        results = [Task.await(first, 5_000), Task.await(second, 5_000)]

        assert Enum.sort(Enum.map(results, fn {:ok, result} -> result.outcome end)) ==
                 [:discard_requested, :duplicate]

        assert Repo.aggregate(
                 from(action in RetentionAction, where: action.action_ref == ^action_ref),
                 :count
               ) == 1
      after
        send(blocker.pid, :release)
        task_key |> Process.delete() |> Ryker.ConcurrencyCase.stop_tasks()
        Repo.delete_all(from(action in RetentionAction, where: action.session_id == ^session.id))
        Repo.delete_all(from(row in Session, where: row.id == ^session.id))

        Repo.delete_all(
          from(event in Ryker.Episodes.Event, where: event.episode_id == ^session.episode_id)
        )

        Repo.delete_all(
          from(episode in Ryker.Episodes.Episode, where: episode.id == ^session.episode_id)
        )
      end
    end)
  end

  # A claim took only the oldest eligible session. While another transaction
  # held that session's episode, the claim found nothing, the pass reported
  # itself idle, and every cleanup behind it waited a whole poll, a minute,
  # for the next one (2026-10-04 review).
  test "a session whose owner is busy is passed over for the next in line" do
    Sandbox.unboxed_run(Repo, fn ->
      busy = terminal_session!("busy-owner")
      next = terminal_session!("next-in-line")
      parent = self()

      # Structural fixture: the busy session's episode ended an hour earlier,
      # so it is first in line.
      Repo.update_all(
        from(episode in Ryker.Episodes.Episode, where: episode.id == ^busy.episode_id),
        set: [updated_at: DateTime.add(Repo.now!(), -3_600, :second)]
      )

      holder =
        Ryker.ConcurrencyCase.unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(episode in Ryker.Episodes.Episode,
                where: episode.id == ^busy.episode_id,
                lock: "FOR UPDATE"
              )
            )

            send(parent, :owner_held)

            receive do
              :release -> :ok
            after
              5_000 -> :ok
            end
          end)
        end)

      try do
        assert_receive :owner_held, 5_000

        assert {:ok, %{session: claimed}} = Custody.claim_next("cleanup:passed-over", 60)
        assert claimed.id == next.id
      after
        send(holder.pid, :release)
        Ryker.ConcurrencyCase.stop_tasks([holder])
        episode_ids = [busy.episode_id, next.episode_id]
        Repo.delete_all(from(row in Session, where: row.episode_id in ^episode_ids))

        Repo.delete_all(
          from(event in Ryker.Episodes.Event, where: event.episode_id in ^episode_ids)
        )

        Repo.delete_all(
          from(episode in Ryker.Episodes.Episode, where: episode.id in ^episode_ids)
        )
      end
    end)
  end

  test "durable evidence does not keep a terminal Coop workspace alive while unpublished review work does" do
    evidence = terminal_session!("open-evidence")
    unpublished = terminal_session!("unpublished-publication")

    insert_open_record!(evidence.episode_id, "evidence")
    insert_unpublished_publication!(unpublished)

    assert {:ok, %{session: claimed}} =
             Ryker.Retention.Custody.claim_next("cleanup:evidence", 60)

    assert claimed.id == evidence.id
    assert claimed.cleanup_status == :close_pending
    assert Repo.get!(Session, unpublished.id).cleanup_status == :active
  end

  # Discard ends a publication for good, and cleanup still read it as work
  # waiting to publish: two finished tasks kept their worker sessions open, and
  # their workspaces with them, from 2026-09-30 with nothing left to wait for.
  test "a discarded publication no longer keeps its finished session open" do
    discarded = terminal_session!("discarded-publication")
    reviewing = terminal_session!("reviewing-publication")
    insert_unpublished_publication!(discarded, "discarded")
    insert_unpublished_publication!(reviewing)

    assert {:ok, %{session: claimed}} = Custody.claim_next("cleanup:discarded", 60)
    assert claimed.id == discarded.id
    assert claimed.cleanup_status == :close_pending
    assert Custody.claim_next("cleanup:reviewing", 60) == {:ok, nil}
    assert Repo.get!(Session, reviewing.id).cleanup_status == :active
  end

  test "cleanup intent makes a reopened episode rotate to a fresh immutable session" do
    session = completed_session!("reopen")
    assert {:ok, _claim} = Ryker.Retention.Custody.claim_next("cleanup:a", 60)

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: session.episode_id,
        episode_key: episode_key!(session.episode_id),
        native_input_id: "source:reopen:new",
        occurred_at: DateTime.add(@now, 10, :second),
        payload: %{"text" => "One more thing."},
        revision: 1,
        turn_ref: "turn:reopen:new"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, rotated} =
             WorkSessions.pin_episode(
               session.episode_id,
               "changed-default",
               String.duplicate("f", 64),
               repository_ref: "changed-repository"
             )

    assert rotated.generation == session.generation + 1
    assert rotated.policy == session.policy
    assert rotated.policy_digest == session.policy_digest
    assert rotated.repository_ref == session.repository_ref
    assert rotated.cleanup_status == :active
  end

  defp waiting_session!(suffix) do
    session = session!(suffix)
    assert {:ok, _claim} = Ryker.Work.Custody.claim_next("work:#{suffix}", 60, :work)

    job =
      session.external_ref
      |> Ryker.Fixtures.WorkerJob.build(session.repository_ref)
      |> Map.put("repository_read_only", true)

    session =
      Repo.update!(
        Ecto.Changeset.change(session,
          worker_job_document: job,
          worker_job_digest: CanonicalJSON.worker_digest(job)
        )
      )

    episode = Repo.get!(Episodes.Episode, session.episode_id)

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 episode_key: episode.key,
                 expected_turn_ref: episode.owner_ref,
                 occurred_at: DateTime.add(@now, 1),
                 result_ref: "result:#{suffix}",
                 delivery: :none,
                 delivery_ref: nil,
                 decision_reason: "Waiting for an event."
               })
               |> Map.put(:next_wait, %{kind: :event, ref: "wait:#{suffix}", deadline_at: nil})
             )

    turn = Repo.one!(from(t in Ryker.Work.Turn, where: t.session_id == ^session.id))

    turn =
      Repo.update!(
        Ecto.Changeset.change(turn,
          status: :settled,
          lease_ref: nil,
          lease_owner: nil,
          lease_expires_at: nil,
          next_attempt_at: nil,
          accepted_at: Repo.now!(),
          candidate: "{}",
          candidate_sha256: String.duplicate("c", 64),
          candidate_attempt: 1,
          validation_intent: %{},
          validation_intent_fingerprint: String.duplicate("d", 64),
          validation_receipt: "accepted",
          result_ref: "result:#{suffix}",
          continuation: %{}
        )
      )

    {session, turn}
  end

  defp session!(suffix) do
    id = Ecto.UUID.generate()
    key = "retention:#{suffix}:#{id}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "source:#{suffix}:#{id}",
                 occurred_at: @now,
                 turn_ref: "turn:#{suffix}:#{id}"
               })
             )

    assert {:ok, session} =
             WorkSessions.pin_episode(id, "work-read-only", String.duplicate("a", 64),
               repository_ref: "ryker"
             )

    session
    |> Ecto.Changeset.change(coop_session_id: "remote:#{suffix}:#{id}")
    |> Repo.update!()
  end

  defp terminal_session!(suffix) do
    session = session!(suffix)

    assert episode = Ryker.Inspectors.episode(episode_key!(session.episode_id))

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{suffix}:#{session.id}",
                 episode_key: episode.key,
                 expected_owner: %{kind: episode.owner_kind, ref: episode.owner_ref},
                 occurred_at: DateTime.add(@now, 1, :second)
               })
             )

    session
  end

  defp create_command!(session, suffix) do
    session = Ryker.Fixtures.WorkerJob.pin!(session)
    worker_id = "retention-worker:#{suffix}:#{session.id}"
    certificate_sha256 = Ryker.Crypto.sha256_hex(worker_id)
    assert {:ok, _worker} = CoopWorkers.authorize(worker_id, "workspace-main", certificate_sha256)

    poll = %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker_id}",
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-test",
        "capabilities" => [],
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
        "clock_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "id" => worker_id,
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }

    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker_id, poll)

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{capability_names: [], repository_ref: nil, workspace_ref: "workspace-main"},
               60
             )

    assert {:ok, command} =
             ControlPlane.enqueue_command(
               placement.id,
               "create_session",
               %{
                 "external_ref" => Session.coop_task_ref(session),
                 "job" => session.worker_job_document,
                 "job_digest" => session.worker_job_digest
               },
               "ryker:work:create:#{session.id}:g#{session.create_generation}"
             )

    command
  end

  defp retained_session!(suffix, dirty, unmerged) do
    session = terminal_session!(suffix)
    assert {:ok, _closed} = grace_and_close!(session, suffix)
    assert {:ok, plan_claim} = Custody.claim_next("cleanup:plan:#{suffix}", 60)
    assert plan_claim.session.id == session.id

    assert {:ok, _frozen} =
             Custody.freeze_plan_revision(session.id, plan_claim.lease_ref, 8, false)

    response = discard_plan(session.coop_session_id, 8, dirty, unmerged)
    assert {:ok, plan} = Plan.prepare(response, session.coop_session_id, 8, false)
    assert {:ok, retained} = Custody.store_plan(session.id, plan_claim.lease_ref, plan, 21_600)
    retained
  end

  defp grace_and_close!(session, suffix) do
    assert {:ok, grace_claim} = Custody.claim_next("cleanup:grace:#{suffix}", 60)
    assert grace_claim.session.id == session.id
    assert {:ok, _grace} = Custody.begin_grace(session.id, grace_claim.lease_ref, 0)
    assert {:ok, close_claim} = Custody.claim_next("cleanup:close:#{suffix}", 60)
    assert close_claim.session.id == session.id
    Custody.mark_closed(session.id, close_claim.lease_ref)
  end

  defp operator_action_task(parent, session_ref, fingerprint, action_ref, label) do
    Ryker.ConcurrencyCase.unboxed_task(fn ->
      send(parent, {:operator_started, label, Ryker.ConcurrencyCase.backend_pid()})
      RetentionOperator.discard_unmerged(session_ref, fingerprint, "operator:local", action_ref)
    end)
  end

  defp completed_session!(suffix) do
    session = session!(suffix)
    assert episode = Ryker.Inspectors.episode(episode_key!(session.episode_id))

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 delivery: :none,
                 decision_reason: "No visible reply was needed.",
                 delivery_ref: nil,
                 episode_key: episode.key,
                 expected_turn_ref: episode.owner_ref,
                 occurred_at: DateTime.add(@now, 1, :second),
                 result_ref: "result:#{suffix}:#{session.id}"
               })
             )

    session
  end

  defp episode_key!(episode_id) do
    Repo.one!(
      from(episode in Ryker.Episodes.Episode,
        where: episode.id == ^episode_id,
        select: episode.key
      )
    )
  end

  defp expire_cleanup_lease!(session_id) do
    {1, nil} =
      Repo.update_all(
        from(session in Session, where: session.id == ^session_id),
        set: [cleanup_lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
      )
  end

  defp insert_open_record!(episode_id, kind \\ "input_request") do
    session = Repo.one!(from(session in Session, where: session.episode_id == ^episode_id))
    turn_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO episode_work_turns
        (id, episode_id, session_id, turn_ref, status,
         submit_generation, validation_generation, cancel_generation,
         work_attempt_count, cancel_attempt_count, delivery_attempt_count,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, 'blocked', 1, 1, 1, 0, 0, 0,
              clock_timestamp(), clock_timestamp())
      """,
      [uuid!(turn_id), uuid!(episode_id), uuid!(session.id), "turn:record:#{turn_id}"]
    )

    Repo.query!(
      """
      INSERT INTO episode_state_records
        (id, episode_id, turn_id, ref, operation_id, kind, status,
         payload, payload_fingerprint, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 'open', '{}', $7,
              clock_timestamp(), clock_timestamp())
      """,
      [
        Ecto.UUID.generate() |> uuid!(),
        uuid!(episode_id),
        uuid!(turn_id),
        "record:#{turn_id}",
        "question",
        kind,
        String.duplicate("b", 64)
      ]
    )
  end

  defp insert_unpublished_publication!(session, status \\ "review_pending") do
    insert_open_record!(session.episode_id)

    {record_id, turn_id} =
      Repo.one!(
        from(record in Ryker.Records.Record,
          where: record.episode_id == ^session.episode_id,
          select: {record.id, record.turn_id},
          limit: 1
        )
      )

    {1, nil} =
      Repo.update_all(
        from(record in Ryker.Records.Record, where: record.id == ^record_id),
        set: [status: :dismissed]
      )

    Repo.query!(
      """
      INSERT INTO episode_publications
        (id, ref, episode_id, record_id, session_id, repository, title, body, status,
         destination_transport, destination_conversation_ref, destination_thread_ref,
         offer_message_ref, review_request_ref, review_requested_by_actor_ref,
         review_requested_at, review_generation, attempt_count, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, 'ryker', 'Review', 'Review this change.',
              $8, 'slack', 'C-retention', 'thread-retention', $6, $7,
              'slack:user:operator', clock_timestamp(), 1, 0,
              clock_timestamp(), clock_timestamp())
      """,
      [
        Ecto.UUID.generate() |> uuid!(),
        "publication:#{session.id}",
        uuid!(session.episode_id),
        uuid!(record_id),
        uuid!(session.id),
        "message:offer:#{session.id}",
        "interaction:review:#{turn_id}",
        status
      ]
    )
  end

  defp discard_plan(session_id, revision, dirty, unmerged) do
    %{
      "operation" => %{
        "id" => "op_plan",
        "method" => "PlanDiscard",
        "resource_id" => session_id,
        "resource_type" => "discard_plan",
        "state" => "succeeded"
      },
      "plan" => %{
        "operation_id" => "op_plan",
        "plan" => %{
          "revision" => revision,
          "session_id" => session_id,
          "workspace" => %{
            "branch" => "coop/session",
            "dirty" => dirty,
            "head" => String.duplicate("c", 40),
            "running" => false,
            "status_digest" => String.duplicate("d", 64),
            "unmerged" => unmerged
          }
        }
      }
    }
  end

  defp uuid!(value), do: Ecto.UUID.dump!(value)
end
