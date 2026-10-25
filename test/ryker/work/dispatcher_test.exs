defmodule Ryker.Work.DispatcherTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  import Ecto.Query
  alias Ryker.CoopFleet.{ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Work.{Cancellation, Custody, Dispatcher, OperationKeys, Result, Submission, Turn}
  alias Ryker.Work.ValidationIntent

  @now ~U[2026-08-28 12:00:00.000000Z]
  @at_capacity "provider service unavailable: Selected model is at capacity. " <>
                 "Please try a different model."

  defmodule ExecutorStub do
    @moduledoc false

    def run(claim, options) do
      before_return = Keyword.get(options, :before_return, fn _claim -> :ok end)
      before_return.(claim)
      Keyword.fetch!(options, :result)
    end
  end

  test "a transient Coop failure is deferred with its lease released" do
    command = create_episode!("transient")
    reason = {:coop_unavailable, :simulated}

    assert {:ok, {:deferred, deferred_reason}} =
             Dispatcher.run_once(options({:error, reason}))

    assert deferred_reason == reason
    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :pending
    assert turn.lease_ref == nil
    assert turn.next_attempt_at != nil
    assert turn.last_error_code == "coop_unavailable"

    assert Dispatcher.run_once(options({:error, reason})) == {:ok, :idle}
  end

  # Coop's answer can quote the request it failed, credentials and all, and the turn kept it as
  # its error detail and the worker logged it as it came (2026-10-04 review).
  test "a turn keeps what went wrong without the credentials the failure quotes" do
    command = create_episode!("redacted-detail")
    reason = {:coop_error, 503, "unavailable", "Authorization: Bearer bearer-secret-value"}

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.last_error_code == "coop_error"
    assert turn.last_error_detail =~ ~s({:coop_error, 503, "unavailable", "Authorization: Bearer)
    refute turn.last_error_detail =~ "bearer-secret-value"
  end

  # A finished turn whose saving hit Coop down, a 5xx, a 429 or a command
  # timeout stopped at once and waited for a click, though trying again
  # finishes it (2026-10-04 review).
  test "a finished turn whose saving hits a passing failure is tried again before it stops" do
    command = create_episode!("completion-transient")
    assert {:ok, _claim} = Custody.claim_next("worker:completion-transient", 60, :work)
    {:ok, rejected} = ValidationIntent.new({:reject, ["Answer the question."]}, nil)

    {1, _rows} =
      Ryker.Repo.update_all(from(saved in Turn, where: saved.episode_id == ^command.episode_id),
        set: [
          candidate: ~s({"delivery":"reply","message":"Done."}),
          candidate_attempt: 1,
          candidate_sha256: String.duplicate("c", 64),
          completion_receipt: %{"state" => "completed"},
          coop_turn_id: "coop-turn-completion-transient",
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          validation_intent: rejected
        ]
      )

    reason = {:coop_error, 503, "unavailable", "try later"}

    options =
      Keyword.merge(options({:error, reason}),
        retry_base_seconds: 3_600,
        retry_max_seconds: 3_600
      )

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(options)

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :pending
    assert turn.completion_receipt == %{"state" => "completed"}
  end

  # 2026-10-12, a question on draft PR AndrewDryga/test#24: the worker picked a finished
  # answer's checkpoint up 42 s late, after Ryker had stopped waiting at 30 s. The checkpoint
  # then succeeded, but the answer was never sent and the task waited for a click. The executor
  # reports every failure to save a finished answer as work_completion_blocked, a shape the
  # retry above never saw: its test returned the bare error.
  test "a finished answer whose saving timed out on the worker is tried again, not stopped" do
    command = create_episode!("completion-timeout")
    proof = finished!(command)
    reason = {:coop_worker_command_timeout, "command:late-checkpoint"}

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(saving_fails(proof, reason))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :pending
    assert turn.completion_receipt == proof
    assert turn.last_error_code == "coop_worker_command_timeout"

    # A failure no retry can change still stops at once, and so does a passing one
    # once the turn's attempts run out.
    refused = {:coop_protocol_error, :completed_turn_state_changed}
    other = create_episode!("completion-refused")

    assert {:ok, {:blocked, ^refused}} =
             Dispatcher.run_once(saving_fails(finished!(other), refused))

    spent = create_episode!("completion-spent")

    assert {:ok, {:blocked, ^reason}} =
             Dispatcher.run_once(
               Keyword.put(saving_fails(finished!(spent), reason), :max_attempts, 2)
             )
  end

  # A person edited or deleted the message after Coop had the turn, or a fact the briefing used
  # was forgotten. Acceptance refused the finished answer, the turn stopped for a person, and
  # "finish saving" refused it again: the answer was stranded (2026-10-04 review). The answer is
  # dropped, and a new turn answers from what is current.
  test "a finished answer whose briefing was withdrawn is answered again from what is current" do
    command = create_episode!("withdrawn-briefing")
    reason = {:work_completion_blocked, %{"state" => "completed"}, :work_knowledge_context_stale}

    assert {:ok, {:deferred, {:work_rerun_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    rerun_ref = "turn:rerun:#{turn.id}"
    assert %{"action" => "transfer", "new_turn_ref" => ^rerun_ref} = turn.cancellation_intent

    assert {:ok, stop} = Custody.claim_next("worker:withdrawn-briefing", 60, :work)
    assert stop.turn.id == turn.id

    {:ok, receipt} =
      Cancellation.absent_receipt(OperationKeys.create(stop.session), nil, nil, nil, nil)

    assert {:ok, settled} =
             Custody.settle_cancellation(
               command.episode_id,
               command.episode_key,
               turn.turn_ref,
               stop.lease_ref,
               receipt
             )

    assert settled.episode.owner_ref == rerun_ref
    assert settled.turn.status == :superseded

    assert {:ok, rerun} = Custody.claim_next("worker:withdrawn-briefing-rerun", 60, :work)
    assert rerun.turn.turn_ref == rerun_ref
  end

  # The same withdrawal found before the answer finished: on 2026-10-07 a later
  # attempt of a turn Coop already had found a fact its briefing used
  # withdrawn, and the turn stopped for a person instead of being answered
  # again from what is current.
  test "a briefing found withdrawn on a later attempt is answered again from what is current" do
    command = create_episode!("withdrawn-on-retry")

    assert Dispatcher.run_once(options({:error, :work_knowledge_context_stale})) ==
             {:ok, {:deferred, {:work_rerun_pending, :work_knowledge_context_stale}}}

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    rerun_ref = "turn:rerun:#{turn.id}"
    assert %{"action" => "transfer", "new_turn_ref" => ^rerun_ref} = turn.cancellation_intent
  end

  # Five requests made over 39,000 unsent turns on 2026-10-25 because every
  # rebuild recalled the same ineligible topic. A new turn must not reset
  # the episode's bounded recovery budget for unchanged stale context.
  test "repeated stale briefings stop after their bounded reruns" do
    command = create_episode!("stale-briefing-loop")
    options = Keyword.put(options({:error, :work_knowledge_context_stale}), :max_attempts, 2)

    for run <- 1..2 do
      assert Dispatcher.run_once(options) ==
               {:ok, {:deferred, {:work_rerun_pending, :work_knowledge_context_stale}}}

      assert {:ok, stop} = Custody.claim_next("worker:stale-briefing-loop", 60, :work)
      assert stop.turn.status == :cancel_pending

      rerun_ref =
        if run == 1,
          do: "turn:rerun:#{stop.turn.id}",
          else: "turn:rerun:#{run}:#{stop.turn.id}"

      assert stop.turn.cancellation_intent["new_turn_ref"] == rerun_ref

      {:ok, receipt} =
        Cancellation.absent_receipt(OperationKeys.create(stop.session), nil, nil, nil, nil)

      assert {:ok, settled} =
               Custody.settle_cancellation(
                 command.episode_id,
                 command.episode_key,
                 stop.turn.turn_ref,
                 stop.lease_ref,
                 receipt
               )

      assert settled.episode.owner_ref == rerun_ref
    end

    assert Dispatcher.run_once(options) ==
             {:ok,
              {:deferred,
               {:work_stop_pending, {:work_retry_exhausted, :work_knowledge_context_stale}}}}
  end

  test "a completed stale answer preserves its proof when its rerun budget is spent" do
    command = create_episode!("stale-completion-loop", "turn:rerun:2:#{Ecto.UUID.generate()}")
    proof = finished!(command)
    reason = {:work_completion_blocked, proof, :work_knowledge_context_stale}

    assert Dispatcher.run_once(
             Keyword.put(saving_fails(proof, :work_knowledge_context_stale), :max_attempts, 2)
           ) == {:ok, {:blocked, {:work_retry_exhausted, reason}}}

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :blocked
    assert turn.completion_receipt == proof
    assert turn.last_error_detail =~ "work_knowledge_context_stale"
  end

  # The bundled Coop worker was paused under a running Chat turn (2026-10-10). Each try while it
  # was away spent one of the turn's eight attempts, 7 s, 8 s, 16 s and 32 s apart, so six were
  # gone after ninety seconds, and a worker away for about three minutes stopped the turn for a
  # person though its next poll would have renewed the placement and the turn would have finished.
  test "a turn keeps its attempts while its worker is away, until the worker is gone" do
    command = create_episode!("worker-away")
    session = Ryker.Repo.get_by!(Ryker.Work.Session, episode_id: command.episode_id)
    WorkerJob.pin!(session)
    authorize_and_poll!("worker-away")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["controller-tools"],
                 repository_ref: nil,
                 workspace_ref: "workspace-main"
               },
               60
             )

    lapse! = fn seconds_ago ->
      Ryker.Repo.update_all(from(p in Placement, where: p.id == ^placement.id),
        set: [lease_expires_at: DateTime.add(Ryker.Repo.now!(), -seconds_ago, :second)]
      )
    end

    reason = {:coop_session_replacement_required, session.id, placement.generation}
    lapse!.(30)

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(options({:error, reason}))

    waiting = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert waiting.work_attempt_count == 0
    assert DateTime.diff(waiting.next_attempt_at, Ryker.Repo.now!()) in 10..15

    # Past the window the worker is gone: the lapse spends attempts again.
    lapse!.(11 * 60)

    {1, _rows} =
      Ryker.Repo.update_all(from(t in Turn, where: t.id == ^waiting.id),
        set: [next_attempt_at: nil]
      )

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(options({:error, reason}))
    assert Ryker.Repo.get_by!(Turn, episode_id: command.episode_id).work_attempt_count == 1
  end

  # The bundled Coop worker restarted under a running Chat turn (2026-10-10). Coop failed the turn
  # as acp_cancelled, and Ryker stopped it for a person at once, though a Retry then answered it.
  # A run the worker interrupted runs again once; a re-run interrupted again stops for a person,
  # so a worker that keeps failing turns cannot loop them.
  test "a turn a worker restart interrupted runs again once, then stops" do
    command = create_episode!("interrupted")
    reason = {:work_turn_terminal, "failed", "acp_cancelled", "turn cancelled"}

    assert {:ok, {:deferred, {:work_rerun_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    rerun_ref = "turn:rerun:#{turn.id}"
    assert %{"action" => "transfer", "new_turn_ref" => ^rerun_ref} = turn.cancellation_intent

    assert {:ok, stop} = Custody.claim_next("worker:interrupted", 60, :work)

    {:ok, receipt} =
      Cancellation.absent_receipt(OperationKeys.create(stop.session), nil, nil, nil, nil)

    assert {:ok, _settled} =
             Custody.settle_cancellation(
               command.episode_id,
               command.episode_key,
               turn.turn_ref,
               stop.lease_ref,
               receipt
             )

    assert {:ok, {:deferred, {:work_stop_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    assert Ryker.Repo.get_by!(Turn, turn_ref: rerun_ref).cancellation_intent["action"] == "block"
  end

  # Three eval turns finished their tools, then sent nothing for 12-18 minutes while their
  # provider pulsed, until their harness gave up (2026-10-12); a live turn would have held its
  # conversation for up to an hour. Coop now stops such a turn as acp_quiet, and Ryker runs it
  # again once on a fresh agent instead of stopping it for a person.
  test "a turn whose model went quiet runs again once" do
    command = create_episode!("quiet")

    reason =
      {:work_turn_terminal, "failed", "acp_quiet", "the model sent nothing for 15m0s"}

    assert {:ok, {:deferred, {:work_rerun_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    rerun_ref = "turn:rerun:#{turn.id}"
    assert %{"action" => "transfer", "new_turn_ref" => ^rerun_ref} = turn.cancellation_intent
  end

  # OpenAI's model was "at capacity" from about 05:25 to 06:10 UTC on 2026-10-13: a question in
  # Slack stopped for a person at once, and a run started by hand at 06:12 answered it. A
  # provider outage passes, so the task runs again by itself once its wait is over.
  test "a task the provider couldn't serve waits, then runs again by itself" do
    command = create_episode!("provider-outage")
    detail = @at_capacity
    reason = {:work_turn_terminal, "failed", "acp_protocol_error", detail}
    failed = {:work_provider_unavailable, DateTime.utc_now(), "acp_protocol_error", detail}

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(options({:error, failed}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :pending
    assert turn.cancellation_intent == nil
    assert turn.work_attempt_count == 0
    assert DateTime.diff(turn.next_attempt_at, DateTime.utc_now()) in 30..90

    Ryker.Repo.update_all(
      from(saved in Turn, where: saved.id == ^turn.id),
      set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
    )

    a_minute_on =
      {:work_provider_unavailable, DateTime.add(DateTime.utc_now(), -61, :second),
       "acp_protocol_error", detail}

    assert {:ok, {:deferred, {:work_rerun_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, a_minute_on}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    rerun_ref = "turn:rerun:#{turn.id}"
    assert %{"action" => "transfer", "new_turn_ref" => ^rerun_ref} = turn.cancellation_intent
  end

  # Each run again after an outage carries its number, so the turn says how many came before it.
  test "a task the provider refuses again runs again under the next number" do
    reason = {:work_turn_terminal, "failed", "acp_protocol_error", @at_capacity}
    command = create_episode!("provider-fourth", "turn:rerun:4:#{Ecto.UUID.generate()}")

    assert {:ok, {:deferred, {:work_rerun_pending, ^reason}}} =
             Dispatcher.run_once(options(provider_failed_long_ago()))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    fifth = "turn:rerun:5:#{turn.id}"
    assert %{"action" => "transfer", "new_turn_ref" => ^fifth} = turn.cancellation_intent
  end

  # The ninth run asks a person: by then the provider has been out for about an hour.
  test "a task the provider keeps refusing asks a person after about an hour" do
    reason = {:work_turn_terminal, "failed", "acp_protocol_error", @at_capacity}
    command = create_episode!("provider-last", "turn:rerun:8:#{Ecto.UUID.generate()}")

    assert {:ok, {:deferred, {:work_stop_pending, ^reason}}} =
             Dispatcher.run_once(options(provider_failed_long_ago()))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.cancellation_intent["action"] == "block"
  end

  defp provider_failed_long_ago do
    long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)
    {:error, {:work_provider_unavailable, long_ago, "acp_protocol_error", @at_capacity}}
  end

  # Coop can report a turn a person stopped the way it reports one a worker restart interrupted,
  # so the re-run above must never replace a person's Stop.
  test "a turn a person stopped is not run again when Coop reports it cancelled" do
    command = create_episode!("stopped-not-rerun")
    reason = {:work_turn_terminal, "failed", "acp_cancelled", "turn cancelled"}

    before_return = fn claim ->
      assert {:ok, _requested} =
               Custody.request_cancel(
                 claim.episode.id,
                 claim.episode.key,
                 claim.turn.turn_ref,
                 "cancel:stopped-not-rerun:#{claim.turn.id}",
                 "Stopped by the operator."
               )
    end

    dispatcher_options =
      options({:error, reason})
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :before_return, before_return))

    assert {:ok, {:lease_lost, ^reason}} = Dispatcher.run_once(dispatcher_options)

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.cancellation_intent["action"] == "cancel"
  end

  test "healthy running Coop work crosses many poll windows without spending failure attempts" do
    Enum.each([:turn, :operation], fn phase ->
      command = create_episode!("healthy-long-#{phase}")
      reason = {:work_poll_window_elapsed, phase}
      dispatcher_options = Keyword.put(options({:error, reason}), :max_attempts, 1)

      for _window <- 1..9 do
        assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(dispatcher_options)

        turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
        assert turn.status == :pending
        assert turn.work_attempt_count == 0
        assert turn.lease_ref == nil

        Ryker.Repo.update_all(
          from(saved in Turn, where: saved.id == ^turn.id),
          set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
        )
      end

      Ryker.Repo.update_all(
        from(saved in Turn, where: saved.episode_id == ^command.episode_id),
        set: [next_attempt_at: nil, status: :blocked]
      )
    end)
  end

  test "a briefly busy historical producer yields without spending attempts or stopping work" do
    command = create_episode!("busy-historical-producer")
    reason = :work_derived_context_busy
    dispatcher_options = Keyword.put(options({:error, reason}), :max_attempts, 1)

    for _window <- 1..3 do
      assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(dispatcher_options)
      turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
      assert turn.status == :pending
      assert turn.work_attempt_count == 0
      assert turn.cancellation_intent == nil

      Ryker.Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
        set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
      )
    end
  end

  test "healthy cancellation reconciliation yields its lease without spending cleanup attempts" do
    command = create_episode!("healthy-cancellation")
    assert {:ok, claim} = Custody.claim_next("worker:prepare-cancellation", 60, :work)

    assert {:ok, requested} =
             Custody.request_block(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               claim.lease_ref,
               "Reconcile the exact remote stop before blocking."
             )

    assert requested.turn.status == :cancel_pending
    reason = {:work_poll_window_elapsed, :operation}

    assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancel_attempt_count == 0
    assert turn.lease_ref == nil
    assert turn.next_attempt_at != nil
  end

  test "an irreducibly uncertain mutation first enters remote-stop custody" do
    command = create_episode!("blocked")
    reason = {:coop_operation_uncertain, "operation_uncertain", "outcome is unknown"}

    assert {:ok, {:deferred, {:work_stop_pending, blocked_reason}}} =
             Dispatcher.run_once(options({:error, {:work_execution_blocked, reason}}))

    assert blocked_reason == reason
    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
    assert turn.lease_ref == nil
    assert turn.next_attempt_at == nil
  end

  test "a repeatedly transient failure stops after its bounded attempt budget" do
    command = create_episode!("retry-budget")
    reason = {:coop_unavailable, :still_down}

    dispatcher_options = Keyword.put(options({:error, reason}), :max_attempts, 1)

    assert {:ok, {:deferred, {:work_stop_pending, {:work_retry_exhausted, ^reason}}}} =
             Dispatcher.run_once(dispatcher_options)

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
    assert turn.work_attempt_count == 1
    assert turn.next_attempt_at == nil
  end

  # An exception inside the executor had no rescue: the worker crashed, the lease ran out, and
  # the turn was claimed and crashed again every lease period, with no attempt cap and no error
  # saved, while the request read as working (2026-10-04 review; executor/validation.ex records
  # one such turn "retrying every five minutes with no error saved").
  test "an executor that raises stops its turn with the exception named" do
    command = create_episode!("raises")

    raising =
      Keyword.update!(
        options({:ok, :unreached}),
        :executor_options,
        &Keyword.put(&1, :before_return, fn _claim -> raise KeyError, key: :missing, term: %{} end)
      )

    assert {:ok, {:deferred, {:work_stop_pending, {:work_host_exception, KeyError}}}} =
             Dispatcher.run_once(raising)

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
    assert turn.cancellation_intent["reason"] =~ "KeyError"
  end

  # A claim spends an attempt before the executor runs, so a turn whose executor kept killing
  # its worker spent attempt after attempt without anything checking the budget.
  test "a turn that used up its attempts is stopped before it runs again" do
    command = create_episode!("spent")

    # The first claim creates the turn; the claims after it crashed before saving anything.
    assert {:ok, {:deferred, _reason}} =
             Dispatcher.run_once(options({:error, {:coop_unavailable, :first_try}}))

    Ryker.Repo.update_all(from(turn in Turn, where: turn.episode_id == ^command.episode_id),
      set: [work_attempt_count: 2, next_attempt_at: nil]
    )

    never =
      options({:ok, :unreached})
      |> Keyword.put(:max_attempts, 2)
      |> Keyword.update!(
        :executor_options,
        &Keyword.put(&1, :before_return, fn _claim -> flunk("a spent turn ran again") end)
      )

    assert Dispatcher.run_once(never) ==
             {:ok, {:deferred, {:work_stop_pending, {:work_retry_exhausted, :attempts}}}}

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
  end

  # The claim takes the oldest claimable episode and rolled back on any error, so an episode
  # whose session could not be set up was chosen again on every poll and no other Work ran at
  # all (2026-10-04 review; the shape of the 2026-09-29 fleet wedge).
  test "an episode that cannot be claimed is skipped and the next one runs" do
    stuck = create_episode!("stuck")
    ready = create_episode!("ready")

    # The stuck one is older, so it is tried first, and its session can never be replaced.
    Ryker.Repo.update_all(from(e in Ryker.Episodes.Episode, where: e.id == ^stuck.episode_id),
      set: [updated_at: DateTime.add(@now, -3_600, :second)]
    )

    Ryker.Repo.update_all(
      from(s in Ryker.Work.Session, where: s.episode_id == ^stuck.episode_id),
      set: [
        cleanup_status: :close_pending,
        worker_job_document: %{"version" => 2},
        worker_job_digest: String.duplicate("0", 64)
      ]
    )

    test = self()

    ran =
      Keyword.update!(
        options({:ok, %{}}),
        :executor_options,
        &Keyword.put(&1, :before_return, fn claim -> send(test, {:ran, claim.episode.id}) end)
      )

    assert {:ok, {:executed, _execution}} = Dispatcher.run_once(ran)
    assert_received {:ran, episode_id}
    assert episode_id == ready.episode_id
  end

  test "the model dispatcher never steals a pending Slack delivery" do
    pending = delivery_pending!("delivery-owned")

    assert Dispatcher.run_once(options({:error, :must_not_run})) == {:ok, :idle}
    assert {:ok, delivery} = Custody.claim_next("worker:delivery", 60, :delivery)
    assert delivery.turn.id == pending.turn.id
  end

  test "every typed recoverable Coop condition is deferred without blocking the queue" do
    reasons = [
      {:work_generation_spent, :turn_submit, {:coop_error, 409, "revision_conflict", "stale"}},
      {:work_cancellation_unresolved, :remote_still_running},
      {:coop_upgrade_required, :repository_freshness_v2},
      # On 2026-09-18 the only worker stopped polling for ninety seconds while
      # one slow command ran. A Work turn waiting on its next, durable and
      # idempotent command was stopped and blocked for an operator, although
      # retrying reconciles that same command once the worker polls again.
      {:coop_worker_command_timeout, "3b0c6f7e-8f1e-4d53-9c1f-2f4f0d7f9a11"},
      {:coop_transport_error, :closed},
      # A repository fetch that stalled past its deadline, or a mirror still
      # held by another fetch, blocked the turn for an operator (2026-09-28
      # review); the next attempt fetches again.
      :coop_worker_source_unavailable,
      {:coop_error, 429, "rate_limited", "try later"},
      {:coop_error, 503, "unavailable", "try later"},
      # Every worker was busy or not reporting yet, and the task stopped for a
      # person at once (2026-10-04 review); that passes on its own.
      {:coop_worker_capacity_unavailable, "1b4d2c9e-1a54-4a52-8d0f-3c1f2a9e7b10"},
      # The worker missed its polls while a slow command held it, and its session's placement
      # lapsed (2026-10-10). A turn whose poll was waiting on the worker then stopped for a person
      # at once, though the worker's next poll renews that placement; the next attempt waits for
      # it or, for a turn Coop does not run yet, moves to a new session.
      {:coop_session_replacement_required, "6f2c1d3e-4b5a-4c69-8e7f-9a0b1c2d3e4f", 3}
    ]

    # A one-second retry let the previous reason's turn fall due again while
    # the full gate ran slowly, and the dispatcher claimed it instead of this
    # one (dev-check, 2026-09-29): each deferral here waits an hour.
    Enum.with_index(reasons, fn reason, index ->
      command = create_episode!("transient-class-#{index}")

      options =
        Keyword.merge(options({:error, reason}),
          retry_base_seconds: 3_600,
          retry_max_seconds: 3_600
        )

      assert {:ok, {:deferred, reported}} = Dispatcher.run_once(options)

      expected =
        case reason do
          {:work_generation_spent, _phase, underlying} -> underlying
          other -> other
        end

      assert reported == expected
      turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
      assert turn.status == :pending
      assert turn.next_attempt_at != nil
    end)
  end

  # A tenant task spent all eight of its tries in two minutes on a repository whose submodule
  # Ryker was never given (2026-10-03). No retry fetches it, so the first refusal stops the
  # task and its saved error names both repositories.
  test "a source refused for its submodule stops the task on the first try" do
    command = create_episode!("refused-companion")
    reason = {:coop_worker_companion_refused, "tenantcorp/tenant-core", "skypjack/entt"}

    assert {:ok, {:deferred, {:work_stop_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.work_attempt_count == 1
  end

  test "an untyped permanent error is bounded before remote-stop custody" do
    command = create_episode!("plain-block")
    reason = String.duplicate("dangerous detail ", 1_000)

    assert {:ok, {:deferred, {:work_stop_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
    assert byte_size(turn.cancellation_intent["reason"]) <= 4_096
    assert String.ends_with?(turn.cancellation_intent["reason"], "...")
  end

  # Stopping a running turn ended its worker's lease, and every stop logged "episode work
  # dispatcher failed": the worker's next write read the ended lease as a missing turn, and the
  # dispatcher tried to stop the turn again with the lease it no longer held (2026-10-04 review).
  test "a turn a person stops while it runs ends its worker's lease, not in a dispatcher failure" do
    command = create_episode!("stopped-while-running")

    before_return = fn claim ->
      assert {:ok, _requested} =
               Custody.request_cancel(
                 claim.episode.id,
                 claim.episode.key,
                 claim.turn.turn_ref,
                 "cancel:stopped-while-running:#{claim.turn.id}",
                 "Stopped by the operator."
               )

      # The executor's next write with its lease, as a running turn makes one each poll.
      assert Custody.renew(claim.episode.id, claim.turn.turn_ref, claim.lease_ref, 60) ==
               {:error, :work_lease_lost}
    end

    dispatcher_options =
      options({:error, :work_lease_lost})
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :before_return, before_return))

    assert Dispatcher.run_once(dispatcher_options) == {:ok, {:lease_lost, :work_lease_lost}}

    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "cancel"
  end

  test "a worker whose lease ended before it saved a retry says so instead of claiming the retry" do
    create_episode!("defer-lost-lease")

    before_return = fn claim ->
      assert {:ok, _deferred} =
               Custody.defer(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 1,
                 "test",
                 "lease deliberately spent"
               )
    end

    dispatcher_options =
      options({:error, {:coop_unavailable, :simulated}})
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :before_return, before_return))

    assert Dispatcher.run_once(dispatcher_options) ==
             {:ok, {:lease_lost, {:coop_unavailable, :simulated}}}
  end

  test "a stale worker cannot stop the healthy claimant that replaced its lease" do
    command = create_episode!("stale-stop-fence")
    replacement = start_supervised!({Agent, fn -> nil end})
    reason = {:coop_protocol_error, :stale_worker_failure}

    before_return = fn claim ->
      assert {:ok, deferred} =
               Custody.defer(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 1,
                 "test",
                 "the first worker deliberately yielded"
               )

      Ryker.Repo.update_all(
        from(saved in Turn, where: saved.id == ^deferred.id),
        set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

      assert {:ok, replacement_claim} =
               Custody.claim_next("worker:stale-stop-replacement", 60, :work)

      Agent.update(replacement, fn _current -> replacement_claim end)
    end

    dispatcher_options =
      options({:error, reason})
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :before_return, before_return))

    assert {:ok, {:lease_lost, ^reason}} = Dispatcher.run_once(dispatcher_options)

    replacement_claim = Agent.get(replacement, & &1)
    turn = Ryker.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :pending
    assert turn.lease_ref == replacement_claim.lease_ref
    assert turn.cancellation_intent == nil
  end

  test "dispatcher configuration rejects each unsafe boundary before claiming work" do
    valid = options({:error, :unused})

    cases = [
      {[], :options},
      {Keyword.put(valid, :unknown, true), :options},
      {Keyword.delete(valid, :worker_ref), :options},
      {Keyword.put(valid, :executor, "module"), :executor},
      {Keyword.put(valid, :executor_options, %{}), :executor_options},
      {Keyword.put(valid, :lease_seconds, 0), :lease_seconds},
      {Keyword.put(valid, :max_attempts, 0), :max_attempts},
      {Keyword.put(valid, :retry_base_seconds, 0), :retry_base_seconds},
      {Keyword.put(valid, :retry_max_seconds, 0), :retry_max_seconds},
      {Keyword.put(valid, :worker_ref, " "), :worker_ref}
    ]

    Enum.each(cases, fn {invalid, field} ->
      assert Dispatcher.run_once(invalid) == {:error, {:invalid_work_dispatcher, field}}
    end)

    assert Dispatcher.run_once(:invalid) == {:error, {:invalid_work_dispatcher, :options}}
  end

  defp create_episode!(suffix, turn_ref \\ nil) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-dispatcher:#{suffix}:#{id}",
        native_input_id: "source:dispatcher:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: turn_ref || "turn:dispatcher:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(id, "work-read-only", String.duplicate("a", 64))

    command
  end

  defp delivery_pending!(suffix) do
    create_episode!(suffix)
    assert {:ok, claim} = Custody.claim_next("worker:prepare-delivery", 60, :work)

    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => claim.episode.id},
               "Handle the selected episode.",
               %{
                 "additionalProperties" => false,
                 "properties" => %{"message" => %{"type" => "string"}},
                 "required" => ["message"],
                 "type" => "object"
               },
               "work-final-live-v3"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{suffix}"
             )

    candidate = ~s({"delivery":"reply","message":"Ready."})
    candidate_sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               claim.episode.id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, %{"message" => "Ready."})

    assert {:ok, _turn} =
             Custody.prepare_validation(
               claim.episode.id,
               turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               claim.episode.id,
               claim.episode.key,
               turn.turn_ref,
               claim.lease_ref,
               candidate_sha256,
               1,
               "validation:#{suffix}"
             )

    accepted
  end

  defp authorize_and_poll!(worker_id) do
    assert {:ok, _worker} = CoopWorkers.authorize(worker_id, "workspace-main", digest(worker_id))

    assert {:ok, _response} =
             ControlPlane.handle_poll_certificate(worker_id, %{
               "acknowledged_command_ids" => [],
               "command_results" => [],
               "event_batches" => [],
               "poll_ref" => "poll:#{worker_id}:hello",
               "version" => 2,
               "worker" => %{
                 "build_version" => "coop-abc123",
                 "capabilities" => [%{"name" => "controller-tools", "version" => "1"}],
                 "capacity" => %{
                   "cooldown_until" => nil,
                   "session_slots_free" => 2,
                   "session_slots_total" => 4,
                   "state" => "eligible",
                   "turn_slots_free" => 2,
                   "turn_slots_total" => 4,
                   "workspace_slots_free" => 2,
                   "workspace_slots_total" => 4
                 },
                 "clock_at" => DateTime.to_iso8601(Ryker.Repo.now!()),
                 "id" => worker_id,
                 "protocol_version" => "2",
                 "sandbox_digest" => String.duplicate("a", 64),
                 "state" => "eligible",
                 "storage" => nil,
                 "workspace_ref" => "workspace-main"
               }
             })
  end

  # A turn as the executor holds it once Coop finished it and Ryker accepted
  # the answer, and the receipt it saves before checkpointing the workspace.
  defp finished!(command) do
    {:ok, result} =
      Result.new(:reply, %{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Done.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    {:ok, accepted} = ValidationIntent.new(:accept, result)
    sha256 = String.duplicate("c", 64)
    remote_id = "coop-turn:#{command.episode_id}"
    assert {:ok, _claim} = Custody.claim_next("worker:#{command.episode_id}", 60, :work)

    {1, _rows} =
      Ryker.Repo.update_all(from(saved in Turn, where: saved.episode_id == ^command.episode_id),
        set: [
          candidate: ~s({"delivery":"reply","message":"Done."}),
          candidate_attempt: 1,
          candidate_sha256: sha256,
          coop_turn_id: remote_id,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          validation_intent: accepted
        ]
      )

    %{
      "candidate_attempt" => 1,
      "candidate_sha256" => sha256,
      "remote_turn_id" => remote_id,
      "validation_receipt" => "validation:#{command.episode_id}"
    }
  end

  # The executor saves the completion receipt, then fails to save the rest, and
  # reports that as work_completion_blocked (`Executor.Turns.completion_result/2`).
  defp saving_fails(proof, reason) do
    record = fn claim ->
      {:ok, _turn} =
        Custody.record_completion(claim.episode.id, claim.turn.turn_ref, claim.lease_ref, proof)
    end

    {:error, {:work_completion_blocked, proof, reason}}
    |> options()
    |> Keyword.update!(:executor_options, &Keyword.put(&1, :before_return, record))
    |> Keyword.merge(retry_base_seconds: 3_600, retry_max_seconds: 3_600)
  end

  defp options(result) do
    [
      executor: ExecutorStub,
      executor_options: [result: result],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "work-dispatcher:test"
    ]
  end
end
