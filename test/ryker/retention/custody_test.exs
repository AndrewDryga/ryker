defmodule Ryker.Retention.CustodyTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Retention.{Custody, Operator, OperatorAction, Plan}
  alias Ryker.Work.Session

  @now ~U[2026-08-29 10:00:00.000000Z]

  test "only one worker claims an exact terminal owned session" do
    active = session!("active")
    terminal = terminal_session!("terminal")

    assert {:ok, claim} = Ryker.Retention.Custody.claim_next("cleanup:a", 60)
    assert claim.session.id == terminal.id
    assert claim.session.cleanup_status == :close_pending
    assert claim.session.cleanup_attempt_count == 1
    assert is_binary(claim.lease_ref)
    assert {:ok, nil} = Ryker.Retention.Custody.claim_next("cleanup:b", 60)

    assert Repo.get!(Session, active.id).cleanup_status == :active
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

    assert {:ok, 1} = Custody.release_worker_leases("cleanup:host-a")

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
             {:error, {:invalid_retention_custody, :reference}}
  end

  test "close and discard phases freeze exact revisions and survive lease turnover" do
    session = terminal_session!("lifecycle")
    assert {:ok, claim} = Ryker.Retention.Custody.claim_next("cleanup:a", 60)

    assert {:ok, frozen} =
             Custody.freeze_close_revision(session.id, claim.lease_ref, 7)

    assert frozen.close_expected_revision == 7

    assert {:ok, same_frozen} = Custody.freeze_close_revision(session.id, claim.lease_ref, 7)
    assert same_frozen.close_expected_revision == 7

    assert {:error, {:retention_close_revision_conflict, 7}} =
             Custody.freeze_close_revision(session.id, claim.lease_ref, 8)

    assert {:error, {:retention_generation_conflict, 1}} =
             Custody.advance_close(session.id, claim.lease_ref, 2)

    assert {:ok, advanced} = Custody.advance_close(session.id, claim.lease_ref, 1)
    assert advanced.close_generation == 2
    assert advanced.close_expected_revision == nil

    assert {:ok, refrozen} = Custody.freeze_close_revision(session.id, claim.lease_ref, 8)
    assert refrozen.close_expected_revision == 8

    assert {:error, :retention_lease_lost} =
             Custody.freeze_close_revision(session.id, "stale", 8)

    assert {:ok, grace} =
             Custody.mark_closed(session.id, claim.lease_ref, 0)

    assert grace.cleanup_status == :grace
    assert grace.cleanup_lease_ref == nil
    assert %DateTime{} = grace.closed_at
    assert DateTime.compare(grace.discard_after, grace.closed_at) in [:eq, :gt]

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

    assert {:error, {:retention_plan_revision_conflict, 8}} =
             Custody.freeze_plan_revision(session.id, plan_claim.lease_ref, 8, true)

    assert {:error, {:retention_generation_conflict, 1}} =
             Custody.advance_plan(session.id, plan_claim.lease_ref, 2)

    plan = discard_plan(session.coop_session_id, 8, false, false)
    assert {:ok, prepared} = Plan.prepare(plan, session.coop_session_id, 8, false)

    assert {:ok, pending} =
             Custody.store_plan(session.id, plan_claim.lease_ref, prepared, 21_600)

    assert pending.cleanup_status == :discard_pending
    assert pending.discard_plan_operation_id == "op_plan"

    expire_cleanup_lease!(pending.id)

    assert {:ok, discard_claim} =
             Custody.claim_next("cleanup:c", 60)

    assert {:error, :retention_remote_session_mismatch} =
             Custody.settle_discard(
               session.id,
               discard_claim.lease_ref,
               "ryker:retention:discard:#{session.id}:g1",
               "remote:wrong"
             )

    assert {:error, :retention_discard_operation_mismatch} =
             Custody.settle_discard(
               session.id,
               discard_claim.lease_ref,
               "wrong-operation",
               session.coop_session_id
             )

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

    assert {:error, :retention_remote_session_bound} =
             Custody.settle_absent(bound.id, bound_claim.lease_ref)
  end

  test "invalid cleanup identities never enter a lease transaction" do
    assert {:error, {:invalid_retention_custody, :reference}} = Custody.claim_next("", 60)

    assert {:error, {:invalid_retention_custody, :lease_seconds}} =
             Custody.claim_next("worker", 0)

    assert {:error, {:invalid_retention_custody, :uuid}} =
             Custody.freeze_close_revision("not-a-uuid", "lease", 1)

    assert {:error, {:invalid_retention_custody, :revision}} =
             Custody.freeze_close_revision(Ecto.UUID.generate(), "lease", 0)

    assert {:error, {:invalid_retention_custody, :plan}} =
             Custody.store_plan(Ecto.UUID.generate(), "lease", nil, 21_600)
  end

  test "dirty and unpublished unmerged plans are durably retained" do
    for {suffix, dirty, unmerged, reason} <- [
          {"dirty", true, false, "dirty"},
          {"unpublished", false, true, "unpublished_unmerged"}
        ] do
      session = terminal_session!(suffix)
      assert {:ok, claim} = Ryker.Retention.Custody.claim_next("cleanup:#{suffix}", 60)

      assert {:ok, _closed} =
               Ryker.Retention.Custody.mark_closed(session.id, claim.lease_ref, 0)

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
    assert {:ok, close_claim} = Custody.claim_next("cleanup:close", 60)
    assert {:ok, _closed} = Custody.mark_closed(session.id, close_claim.lease_ref, 0)
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
             Operator.rearm(
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
             Operator.rearm(
               session.external_ref,
               "operator:local",
               "retention-action:rearm:one"
             )

    assert Repo.aggregate(Ryker.Retention.OperatorAction, :count) == 1

    assert {:error, :retention_operator_action_conflict} =
             Operator.discard_unmerged(
               session.external_ref,
               "operator:local",
               "retention-action:rearm:one"
             )
  end

  test "explicit unmerged discard refreshes the exact plan while dirty work stays retained" do
    unmerged = retained_session!("operator-unmerged", false, true)
    dirty = retained_session!("operator-dirty", true, false)

    assert {:ok, %{action: discard_action, outcome: :discard_requested, session: replanning}} =
             Operator.discard_unmerged(
               unmerged.external_ref,
               "operator:local",
               "retention-action:discard:unmerged"
             )

    assert discard_action.request_fingerprint ==
             CanonicalJSON.digest(%{
               "action" => "discard_unmerged",
               "actor_ref" => "operator:local",
               "session_ref" => unmerged.external_ref
             })

    assert replanning.cleanup_status == :plan_pending
    assert replanning.discard_plan_accept_unmerged
    assert replanning.discard_plan_generation == unmerged.discard_plan_generation + 1
    assert replanning.discard_plan == nil
    assert replanning.discard_plan_fingerprint == nil
    assert replanning.retained_reason == nil

    assert {:ok, %{outcome: :duplicate}} =
             Operator.discard_unmerged(
               unmerged.external_ref,
               "operator:local",
               "retention-action:discard:unmerged"
             )

    assert {:error, :retention_dirty_workspace} =
             Operator.discard_unmerged(
               dirty.external_ref,
               "operator:local",
               "retention-action:discard:dirty"
             )

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

        first = operator_action_task(parent, session.external_ref, action_ref, :first)
        Process.put(task_key, [first | Process.get(task_key)])
        assert_receive {:operator_started, :first, first_backend}, 5_000
        Ryker.ConcurrencyCase.await_blocked_by(first_backend, blocker_backend)

        second = operator_action_task(parent, session.external_ref, action_ref, :second)
        Process.put(task_key, [second | Process.get(task_key)])
        assert_receive {:operator_started, :second, second_backend}, 5_000
        Ryker.ConcurrencyCase.await_blocked_by(second_backend, first_backend)

        send(blocker.pid, :release)
        assert {:ok, _transaction} = Task.await(blocker, 5_000)

        results = [Task.await(first, 5_000), Task.await(second, 5_000)]

        assert Enum.sort(Enum.map(results, fn {:ok, result} -> result.outcome end)) ==
                 [:discard_requested, :duplicate]

        assert Repo.aggregate(
                 from(action in OperatorAction, where: action.action_ref == ^action_ref),
                 :count
               ) == 1
      after
        send(blocker.pid, :release)
        task_key |> Process.delete() |> Ryker.ConcurrencyCase.stop_tasks()
        Repo.delete_all(from(action in OperatorAction, where: action.session_id == ^session.id))
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
             Ryker.Work.Custody.pin_episode(
               session.episode_id,
               "changed-default",
               String.duplicate("f", 64),
               "changed-repository"
             )

    assert rotated.generation == session.generation + 1
    assert rotated.policy == session.policy
    assert rotated.policy_digest == session.policy_digest
    assert rotated.repository_ref == session.repository_ref
    assert rotated.cleanup_status == :active
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
             Ryker.Work.Custody.pin_episode(
               id,
               "work-read-only",
               String.duplicate("a", 64),
               "ryker"
             )

    session
    |> Ecto.Changeset.change(coop_session_id: "remote:#{suffix}:#{id}")
    |> Repo.update!()
  end

  defp terminal_session!(suffix) do
    session = session!(suffix)

    assert {:ok, episode} = Episodes.fetch_by_key(episode_key!(session.episode_id))

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

  defp retained_session!(suffix, dirty, unmerged) do
    session = terminal_session!(suffix)
    assert {:ok, close_claim} = Custody.claim_next("cleanup:close:#{suffix}", 60)
    assert close_claim.session.id == session.id
    assert {:ok, _closed} = Custody.mark_closed(session.id, close_claim.lease_ref, 0)
    assert {:ok, plan_claim} = Custody.claim_next("cleanup:plan:#{suffix}", 60)
    assert plan_claim.session.id == session.id

    assert {:ok, _frozen} =
             Custody.freeze_plan_revision(session.id, plan_claim.lease_ref, 8, false)

    response = discard_plan(session.coop_session_id, 8, dirty, unmerged)
    assert {:ok, plan} = Plan.prepare(response, session.coop_session_id, 8, false)
    assert {:ok, retained} = Custody.store_plan(session.id, plan_claim.lease_ref, plan, 21_600)
    retained
  end

  defp operator_action_task(parent, session_ref, action_ref, label) do
    Ryker.ConcurrencyCase.unboxed_task(fn ->
      send(parent, {:operator_started, label, Ryker.ConcurrencyCase.backend_pid()})
      Operator.discard_unmerged(session_ref, "operator:local", action_ref)
    end)
  end

  defp completed_session!(suffix) do
    session = session!(suffix)
    assert {:ok, episode} = Episodes.fetch_by_key(episode_key!(session.episode_id))

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

  defp insert_unpublished_publication!(session) do
    insert_open_record!(session.episode_id)

    {record_id, turn_id} =
      Repo.one!(
        from(record in Ryker.State.Record,
          where: record.episode_id == ^session.episode_id,
          select: {record.id, record.turn_id},
          limit: 1
        )
      )

    {1, nil} =
      Repo.update_all(
        from(record in Ryker.State.Record, where: record.id == ^record_id),
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
              'review_pending', 'slack', 'C-retention', 'thread-retention', $6, $7,
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
        "interaction:review:#{turn_id}"
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
