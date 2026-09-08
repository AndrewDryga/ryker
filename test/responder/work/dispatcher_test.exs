defmodule Responder.Work.DispatcherTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Work.{Custody, Dispatcher, Result, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

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
    turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :pending
    assert turn.lease_ref == nil
    assert turn.next_attempt_at != nil
    assert turn.last_error_code == "coop_unavailable"

    assert {:ok, :idle} = Dispatcher.run_once(options({:error, reason}))
  end

  test "healthy running Coop work crosses many poll windows without spending failure attempts" do
    Enum.each([:turn, :operation], fn phase ->
      command = create_episode!("healthy-long-#{phase}")
      reason = {:work_poll_window_elapsed, phase}
      dispatcher_options = Keyword.put(options({:error, reason}), :max_attempts, 1)

      for _window <- 1..9 do
        assert {:ok, {:deferred, ^reason}} = Dispatcher.run_once(dispatcher_options)

        turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
        assert turn.status == :pending
        assert turn.work_attempt_count == 0
        assert turn.lease_ref == nil

        Responder.Repo.update_all(
          from(saved in Turn, where: saved.id == ^turn.id),
          set: [next_attempt_at: ~U[2000-01-01 00:00:00.000000Z]]
        )
      end

      Responder.Repo.update_all(
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
      turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
      assert turn.status == :pending
      assert turn.work_attempt_count == 0
      assert turn.cancellation_intent == nil

      Responder.Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
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

    turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
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
    turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
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

    turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
    assert turn.work_attempt_count == 1
    assert turn.next_attempt_at == nil
  end

  test "the model dispatcher never steals a pending Slack delivery" do
    pending = delivery_pending!("delivery-owned")

    assert {:ok, :idle} = Dispatcher.run_once(options({:error, :must_not_run}))
    assert {:ok, delivery} = Custody.claim_next("worker:delivery", 60, :delivery)
    assert delivery.turn.id == pending.turn.id
  end

  test "every typed recoverable Coop condition is deferred without blocking the queue" do
    reasons = [
      {:work_generation_spent, :turn_submit, {:coop_error, 409, "revision_conflict", "stale"}},
      {:work_cancellation_unresolved, :remote_still_running},
      {:coop_upgrade_required, :repository_freshness_v2},
      {:coop_timeout, :turn},
      {:coop_transport_error, :closed},
      {:coop_error, 429, "rate_limited", "try later"},
      {:coop_error, 503, "unavailable", "try later"}
    ]

    Enum.with_index(reasons, fn reason, index ->
      command = create_episode!("transient-class-#{index}")

      assert {:ok, {:deferred, reported}} = Dispatcher.run_once(options({:error, reason}))

      expected =
        case reason do
          {:work_generation_spent, _phase, underlying} -> underlying
          other -> other
        end

      assert reported == expected
      turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
      assert turn.status == :pending
      assert turn.next_attempt_at != nil
    end)
  end

  test "an untyped permanent error is bounded before remote-stop custody" do
    command = create_episode!("plain-block")
    reason = String.duplicate("dangerous detail ", 1_000)

    assert {:ok, {:deferred, {:work_stop_pending, ^reason}}} =
             Dispatcher.run_once(options({:error, reason}))

    turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
    assert turn.status == :cancel_pending
    assert turn.cancellation_intent["action"] == "block"
    assert byte_size(turn.cancellation_intent["reason"]) <= 4_096
    assert String.ends_with?(turn.cancellation_intent["reason"], "...")
  end

  test "a lost lease while recording retry is reported instead of hiding the failure" do
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
      options({:error, {:coop_timeout, :turn}})
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :before_return, before_return))

    assert {:error, {:work_dispatch_failed, {:coop_timeout, :turn}, :work_turn_not_found}} =
             Dispatcher.run_once(dispatcher_options)
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

      Responder.Repo.update_all(
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

    assert {:error, {:work_dispatch_failed, ^reason, :work_lease_lost}} =
             Dispatcher.run_once(dispatcher_options)

    replacement_claim = Agent.get(replacement, & &1)
    turn = Responder.Repo.get_by!(Turn, episode_id: command.episode_id)
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

  defp create_episode!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-dispatcher:#{suffix}:#{id}",
        native_input_id: "source:dispatcher:#{suffix}:#{id}",
        occurred_at: @now,
        turn_ref: "turn:dispatcher:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))

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
               "work-final-v1"
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
    candidate_sha256 = :crypto.hash(:sha256, candidate) |> Base.encode16(case: :lower)

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
