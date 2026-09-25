defmodule Ryker.Work.CancellationWorkerTest do
  @moduledoc """
  Stopping a run when the worker that holds it changed or went away.

  A run counts as stopped only on its worker's word. These tests hold the
  cases where that word can never come, or where Ryker refused to ask for it,
  to the invariant that a stop finishes or says what would finish it.
  """

  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CoopFleet.{Client, ControlPlane, Placement, WorkerLifecycle}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Cancellation, Custody, Dispatcher, Submission, Turn}

  @policy "ryker-chat"
  @started String.duplicate("a", 64)
  @newer String.duplicate("3", 64)
  @authority String.duplicate("9", 64)
  @sandbox String.duplicate("c", 64)
  @workspace "workspace-cancellation-worker"
  @requirements %{
    capability_names: ["responder-state"],
    repository_ref: nil,
    workspace_ref: "workspace-cancellation-worker"
  }

  # Found reading Work cancellation on 2026-09-24: a stop only settles on the
  # worker's own terminal answer, and every failed attempt was deferred with no
  # limit. When the worker holding the run was removed from Ryker, the task
  # read "stopping" forever, held its request (or the next message) behind it,
  # and was listed nowhere. A removed worker's certificates, placement and state
  # tools are all revoked, so nothing that run does can reach Ryker again; that
  # removal is the proof no answer can give.
  test "a stop whose worker was removed from Ryker completes instead of stopping forever" do
    worker = enroll!("removed")
    work = bound_turn!("removed", worker)

    assert {:ok, %{status: :pending}} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:removed:#{work.turn.id}",
               "Closed as no longer needed."
             )

    assert {:ok, %{status: :revoked}} = WorkerLifecycle.revoke(worker, "operator:test")
    assert {:ok, claim} = Custody.claim_next("worker:removed-stop", 60, :work)
    assert claim.turn.status == :cancel_pending

    assert {:ok, {:executed, execution}} = Dispatcher.run_claim(claim, dispatcher(worker))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled

    stopped = Repo.get!(Turn, work.turn.id)
    assert stopped.status == :superseded

    assert stopped.cancellation_receipt == %{
             "kind" => "worker_removed",
             "remote_session_id" => work.session.coop_session_id,
             "remote_turn_id" => work.turn.coop_turn_id,
             "worker_id" => worker
           }
  end

  # The same stop, when the worker is still there but was moved to a newer
  # version of the run's policy (a model change in Settings): placement refused
  # every command for the run, so its cancel could never be sent and the stop
  # was deferred forever. Cancelling and closing do no policy work.
  test "a stop reaches the worker that holds its run after the worker's policy changed" do
    worker = enroll!("newer-policy")
    work = bound_turn!("newer-policy", worker)

    assert {:ok, %{status: :pending}} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:newer-policy:#{work.turn.id}",
               "Stopped by the operator."
             )

    poll!(worker, @newer)
    expire_placements!(work.session)

    # The first call retires the placement whose lease ended; the next places anew.
    assert {:error, {:coop_session_replacement_required, _session, 1}} =
             ControlPlane.place_session(work.session.id, @requirements, 60)

    assert {:ok, holder} = ControlPlane.place_session(work.session.id, @requirements, 60)
    assert holder.worker_id == worker
    assert holder.generation == 2
    assert holder.requirements["policy_digest"] == @newer
  end

  # The placement that let a stop through under a newer policy version must not
  # outlive the stop as a way to run new work in a session that started under
  # the old one: a session is only ever worked under the version it started with.
  test "a placement that stopped a run under a newer policy never carries the next turn" do
    worker = enroll!("fenced")
    work = bound_turn!("fenced", worker)
    new_turn_ref = "turn:fenced:next:#{work.turn.id}"

    assert {:ok, %{status: :pending}} =
             Custody.request_transfer(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               new_turn_ref,
               "transfer:fenced:#{work.turn.id}"
             )

    poll!(worker, @newer)
    expire_placements!(work.session)
    _retired = ControlPlane.place_session(work.session.id, @requirements, 60)
    assert {:ok, holder} = ControlPlane.place_session(work.session.id, @requirements, 60)

    # The worker proved the run stopped; the transfer keeps the session open.
    assert {:ok, claim} = Custody.claim_next("worker:fenced-stop", 60, :work)

    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               work.session.coop_session_id,
               work.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(work.turn.id, 1),
               "open",
               nil
             )

    assert {:ok, %{episode: %{owner_ref: ^new_turn_ref}}} =
             Custody.settle_cancellation(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               claim.lease_ref,
               receipt
             )

    session_id = work.session.id
    generation = holder.generation

    assert {:error, {:coop_session_replacement_required, ^session_id, ^generation}} =
             ControlPlane.place_session(work.session.id, @requirements, 60)

    # Cleanup of the same session still reaches its worker through it.
    assert Repo.get!(Placement, holder.id).state == :active
  end

  defp dispatcher(worker) do
    assert {:ok, client} =
             Client.new(
               capability_names: ["responder-state"],
               lease_seconds: 60,
               max_waits: 1,
               poll_interval_ms: 1,
               wait: fn -> flunk("no command may be sent to removed worker #{worker}") end,
               workspace_ref: @workspace
             )

    [executor_options: [api: Client, client: client], worker_ref: "work:#{worker}"]
  end

  defp enroll!(suffix) do
    worker = "stop-#{suffix}-#{System.unique_integer([:positive])}"
    certificate = :crypto.hash(:sha256, worker) |> Base.encode16(case: :lower)
    assert {:ok, _worker} = ControlPlane.authorize_worker(worker, @workspace, certificate)
    poll!(worker, @started)
    worker
  end

  defp poll!(worker, digest) do
    assert {:ok, _response} =
             ControlPlane.handle_poll(worker, %{
               "acknowledged_command_ids" => [],
               "command_results" => [],
               "event_batches" => [],
               "poll_ref" => "poll:#{worker}:#{System.unique_integer([:positive])}",
               "version" => 1,
               "worker" => %{
                 "build_version" => "coop-cancellation-worker",
                 "capabilities" => [%{"name" => "responder-state", "version" => "1"}],
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
                 "clock_at" => DateTime.to_iso8601(database_now!()),
                 "id" => worker,
                 "policy_authority_digests" => %{@policy => @authority},
                 "policy_digests" => %{@policy => digest},
                 "protocol_version" => "1",
                 "repositories" => [],
                 "sandbox_digest" => @sandbox,
                 "state" => "eligible",
                 "workspace_ref" => @workspace
               }
             })
  end

  # A run bound on this worker: its session created there under @started.
  defp bound_turn!(suffix, worker) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-stop-worker:#{suffix}:#{id}",
        native_input_id: "source:stop-worker:#{suffix}:#{id}",
        occurred_at: database_now!(),
        turn_ref: "turn:stop-worker:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    assert {:ok, pinned} = Custody.pin_episode(id, @policy, @started, @authority, nil)
    assert {:ok, placement} = ControlPlane.place_session(pinned.id, @requirements, 60)
    assert placement.worker_id == worker
    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60, :work)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => suffix},
               "Handle the request.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, command.turn_ref, claim.lease_ref, submission)

    assert {:ok, session} =
             Custody.bind_session(
               id,
               command.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote_stop_#{suffix}_#{String.replace(id, "-", "")}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               id,
               command.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "turn_stop_#{suffix}_#{String.replace(id, "-", "")}"
             )

    %{episode: claim.episode, session: session, turn: turn}
  end

  # The placement lease ran out while nothing addressed the session.
  defp expire_placements!(session) do
    Repo.update_all(
      from(placement in Placement, where: placement.session_id == ^session.id),
      set: [lease_expires_at: DateTime.add(database_now!(), -1, :second)]
    )
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
