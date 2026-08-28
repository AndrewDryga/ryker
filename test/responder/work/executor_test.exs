defmodule Responder.Work.ExecutorTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.TestSupport.FakeWorkCoopAPI, as: FakeAPI
  alias Responder.Work.{Cancellation, Custody, Executor, Final, Result, SubmissionBuilder}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule ProtocolAPI do
    @moduledoc false
    @behaviour Responder.Coop.API

    alias Responder.TestSupport.FakeWorkCoopAPI, as: FakeAPI

    def operation_by_key(client, key),
      do:
        dispatch(client, :operation_by_key, fn -> FakeAPI.operation_by_key(client.fake, key) end)

    def create_session(client, key, policy, task),
      do:
        dispatch(client, :create_session, fn ->
          FakeAPI.create_session(client.fake, key, policy, task)
        end)

    def fence_create_session(client, key, policy, task),
      do:
        dispatch(client, :fence_create_session, fn ->
          FakeAPI.fence_create_session(client.fake, key, policy, task)
        end)

    def get_session(client, session_id),
      do: dispatch(client, :get_session, fn -> FakeAPI.get_session(client.fake, session_id) end)

    def close_session(client, session_id, key, revision),
      do:
        dispatch(client, :close_session, fn ->
          FakeAPI.close_session(client.fake, session_id, key, revision)
        end)

    def submit_turn(client, session_id, key, revision, prompt, schema),
      do:
        dispatch(client, :submit_turn, fn ->
          FakeAPI.submit_turn(client.fake, session_id, key, revision, prompt, schema)
        end)

    def fence_submit_turn(client, session_id, key, revision, prompt, schema),
      do:
        dispatch(client, :fence_submit_turn, fn ->
          FakeAPI.fence_submit_turn(client.fake, session_id, key, revision, prompt, schema)
        end)

    def get_turn(client, session_id, turn_id),
      do:
        dispatch(client, :get_turn, fn -> FakeAPI.get_turn(client.fake, session_id, turn_id) end)

    def validate_candidate(client, session_id, turn_id, key, sha256, verdict),
      do:
        dispatch(client, :validate_candidate, fn ->
          FakeAPI.validate_candidate(
            client.fake,
            session_id,
            turn_id,
            key,
            sha256,
            verdict
          )
        end)

    def cancel_turn(client, session_id, turn_id, key, revision),
      do:
        dispatch(client, :cancel_turn, fn ->
          FakeAPI.cancel_turn(client.fake, session_id, turn_id, key, revision)
        end)

    defp dispatch(client, name, fallback) do
      case Map.fetch(client.overrides, name) do
        :error -> fallback.()
        {:ok, function} when is_function(function, 1) -> function.(fallback)
        {:ok, response} -> response
      end
    end
  end

  test "one frozen turn reaches a validated durable delivery intent" do
    claim = claim_episode!("valid")
    {:ok, fake} = FakeAPI.start_link([reply("Investigation complete.")])

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted
    assert execution.turn.status == :delivery_pending
    assert execution.episode.owner_kind == :delivery

    state = FakeAPI.state(fake)
    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert state.submissions |> hd() |> Map.fetch!(:schema) == Final.json_schema()
    refute state.submissions |> hd() |> Map.fetch!(:prompt) =~ ~s("$schema")
  end

  test "a semantic rejection repairs in the same Coop turn and keeps one accepted result" do
    # Production had 98 correction events across 41 recent episodes; the host
    # must return useful violations without starting another model session.
    claim = claim_episode!("same-turn-repair")

    {:ok, fake} =
      FakeAPI.start_link([
        silent("No reply is needed."),
        reply("I checked the request and here is the answer.")
      ])

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted

    assert execution.turn.delivery_document["message"] ==
             "I checked the request and here is the answer."

    state = FakeAPI.state(fake)
    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]

    assert state.validations |> hd() |> Map.fetch!(:violations) |> hd() =~
             "explicit human request"
  end

  test "a lost validation response reconciles the exact candidate without another model turn" do
    claim = claim_episode!("validation-response-loss")

    {:ok, fake} =
      FakeAPI.start_link([reply("This answer survives the lost response.")],
        lose_first_validation_response: true
      )

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted
    assert execution.turn.validation_receipt != nil

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert length(state.validation_keys) == 1
    assert state.operation_calls[hd(state.validation_keys)] >= 1
  end

  test "a lost submit response reconciles one remote turn from the frozen submission" do
    claim = claim_episode!("submit-response-loss")

    {:ok, fake} =
      FakeAPI.start_link([reply("The original turn was recovered.")],
        lose_first_submit_response: true
      )

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert length(Enum.uniq(state.turn_keys)) == 1
    assert state.operation_calls[hd(state.turn_keys)] >= 1
  end

  test "only the exact recoverable cleanup failure spends validation identity" do
    candidate = reply("Validation cleanup can be retried safely.")
    candidate_sha256 = digest(candidate)

    retry_claim = claim_episode!("validation-cleanup-retry")
    {:ok, retry_fake} = FakeAPI.start_link([candidate])

    retry_key =
      "responder:work:validate:#{retry_claim.turn.id}:a1:g1:#{candidate_sha256}:accept"

    FakeAPI.seed_operation(
      retry_fake,
      retry_key,
      failed_operation("session_cleanup_error", "ValidateTurnCandidate")
    )

    assert {:error,
            {:work_generation_spent, :validation,
             {:coop_operation_failed, "session_cleanup_error", _detail}}} =
             Executor.run(retry_claim, options(retry_fake))

    retried = Responder.Repo.get!(Responder.Work.Turn, retry_claim.turn.id)
    assert retried.validation_generation == 2

    blocked_claim = claim_episode!("validation-invalid-blocked")
    {:ok, blocked_fake} = FakeAPI.start_link([candidate])
    FakeAPI.seed_turn(blocked_fake, "remote_work_blocked", "unused", "running")

    blocked_key =
      "responder:work:validate:#{blocked_claim.turn.id}:a1:g1:#{candidate_sha256}:accept"

    failure = failed_operation("invalid_request", "ValidateTurnCandidate")
    FakeAPI.seed_operation(blocked_fake, blocked_key, failure)

    assert {:error,
            {:work_execution_blocked, {:coop_operation_failed, "invalid_request", _detail}}} =
             Executor.run(blocked_claim, options(blocked_fake))

    blocked = Responder.Repo.get!(Responder.Work.Turn, blocked_claim.turn.id)
    assert blocked.validation_generation == 1
  end

  test "a lost Coop cancel response is proven from the remote turn before the episode stops" do
    work = bound_turn!("cancel-response-loss")

    {:ok, fake} =
      fake_for(work, [], lose_first_cancel_response: true)

    FakeAPI.seed_turn(
      fake,
      work.session.coop_session_id,
      work.turn.coop_turn_id,
      "running"
    )

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:#{work.turn.id}",
               "Stopped by the operator."
             )

    assert requested.status == :pending
    assert {:ok, claim} = Custody.claim_next("worker:cancel-runtime", 60)

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled
    assert execution.turn.status == :superseded

    state = FakeAPI.state(fake)
    assert length(state.cancel_keys) == 1
    assert state.lost_cancel_response
    assert state.turn["state"] == "cancelled"
  end

  test "stop reconciles an admitted submit whose turn response was lost" do
    work = claim_with_bound_session!("cancel-lost-submit-binding")
    {:ok, fake} = fake_for(work, [])
    remote_turn_id = "remote-turn:lost-submit:#{work.turn.id}"

    assert {:ok, turn} =
             Custody.renew(work.episode.id, work.turn.turn_ref, work.lease_ref, 60)

    work = %{work | turn: turn}

    assert :ok =
             prepare_remote_operation(work, :submit_turn, turn_key(work), 1, fn ->
               FakeAPI.seed_operation(
                 fake,
                 turn_key(work),
                 succeeded_operation("SubmitTurn", "turn", remote_turn_id)
               )

               FakeAPI.seed_turn(fake, work.session.coop_session_id, remote_turn_id, "running")
               :ok
             end)

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:lost-submit:#{work.turn.id}",
               "Stopped while the submit response was unresolved."
             )

    assert requested.status == :pending
    assert requested.turn.status == :cancel_pending
    assert requested.turn.coop_turn_id == nil
    assert requested.turn.next_attempt_at == nil

    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-lost-submit", 60, :work)
    assert cancel_claim.turn.coop_turn_id == nil

    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled
    assert execution.turn.coop_turn_id == remote_turn_id
    assert FakeAPI.state(fake).turn["state"] == "cancelled"
  end

  test "stop fences a frozen submit without creating work after authority was revoked" do
    work = claim_with_bound_session!("cancel-submit-before-operation-journal")
    {:ok, fake} = fake_for(work, [reply("This turn must be cancelled, not delivered.")])
    key = turn_key(work)

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :submit_turn,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: 1
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:pre-journal-submit:#{work.turn.id}",
               "Stop while Coop may still admit the frozen submit."
             )

    assert requested.turn.remote_operation_kind == "submit_turn"
    assert requested.turn.remote_operation_revision == 1
    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-pre-journal-submit", 60)

    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled

    state = FakeAPI.state(fake)
    assert state.submit_count == 0
    assert state.submissions == []
    assert state.fence_submit_keys == [key]
    assert state.turn == nil
  end

  test "stop fences a frozen create without creating a session after authority was revoked" do
    work = claim_episode!("cancel-create-before-operation-journal")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = create_key(work)

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :create_session,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: nil
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:pre-journal-create:#{work.turn.id}",
               "Stop while Coop may still admit the frozen create."
             )

    assert requested.turn.remote_operation_kind == "create_session"
    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-pre-journal-create", 60)

    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))
    assert execution.status == :cancelled
    assert execution.episode.state == :cancelled

    state = FakeAPI.state(fake)
    assert state.create_count == 0
    assert state.create_keys == []
    assert state.fence_create_keys == [key]
  end

  test "stop fences the exact create instead of trusting a present hashless lookup" do
    work = claim_episode!("cancel-create-fence-conflict")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = create_key(work)
    remote_session_id = FakeAPI.state(fake).session["id"]

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :create_session,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: nil
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:create-fence-conflict:#{work.turn.id}",
               "Stop must not adopt another create request that reused this key."
             )

    assert {:ok, cancel_claim} = Custody.claim_next("worker:create-fence-conflict", 60)

    wrong_operation =
      succeeded_operation("CreateRemoteSession", "session", remote_session_id)

    FakeAPI.seed_operation(fake, key, wrong_operation)

    overrides = %{
      fence_create_session:
        {:error, {:coop_error, 409, "idempotency_conflict", "the key belongs to another body"}}
    }

    assert {:error,
            {:work_cancellation_unresolved,
             {:fence_idempotency_conflict, {:coop_error, 409, "idempotency_conflict", _detail}}}} =
             Executor.run(cancel_claim, protocol_options(fake, overrides))

    assert Map.get(FakeAPI.state(fake).operation_calls, key, 0) == 0
    assert FakeAPI.state(fake).session["state"] == "open"
  end

  test "stop never trusts a hashless lookup after a lost submit fence response" do
    work = claim_with_bound_session!("cancel-submit-fence-conflict")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = turn_key(work)
    wrong_turn_id = "remote-turn:wrong-body:#{work.turn.id}"

    FakeAPI.seed_turn(fake, work.session.coop_session_id, wrong_turn_id, "running")

    assert Custody.with_mutation_fence(
             work.episode.id,
             work.turn.turn_ref,
             work.lease_ref,
             %{
               kind: :submit_turn,
               lease_seconds: 60,
               maximum_block_ms: 1_000,
               operation_key: key,
               operation_revision: 1
             },
             fn -> {:error, :simulated_loss_before_operation_reservation} end
           ) == {:error, :simulated_loss_before_operation_reservation}

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:submit-fence-conflict:#{work.turn.id}",
               "Stop must not adopt another submit request that reused this key."
             )

    assert {:ok, cancel_claim} = Custody.claim_next("worker:submit-fence-conflict", 60)
    {:ok, lookup_count} = Agent.start_link(fn -> 0 end)

    wrong_operation = succeeded_operation("SubmitTurn", "turn", wrong_turn_id)

    overrides = %{
      fence_submit_turn: {:error, {:coop_unavailable, :simulated_fence_response_loss}},
      operation_by_key: first_not_found_then(lookup_count, wrong_operation)
    }

    assert {:error,
            {:work_cancellation_unresolved,
             {:turn_submit_fence, {:error, {:coop_unavailable, :simulated_fence_response_loss}}}}} =
             Executor.run(cancel_claim, protocol_options(fake, overrides))

    assert Agent.get(lookup_count, & &1) == 0
    assert FakeAPI.state(fake).turn["state"] == "running"
    assert FakeAPI.state(fake).cancel_keys == []
  end

  test "stop reconciles a succeeded create journal before closing the proven session" do
    work = claim_episode!("cancel-succeeded-create-journal")
    {:ok, fake} = fake_for(work, [reply("unused")])
    key = create_key(work)

    assert {:ok, %{"operation" => operation, "session" => remote_session}} =
             prepare_remote_operation(work, :create_session, key, nil, fn ->
               FakeAPI.create_session(
                 fake,
                 key,
                 work.session.policy,
                 work.session.external_ref
               )
             end)

    assert operation["method"] == "CreateRemoteSession"
    assert remote_session["state"] == "open"

    assert {:ok, requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:succeeded-create:#{work.turn.id}",
               "Stop after the create response was lost."
             )

    assert requested.turn.coop_turn_id == nil
    assert {:ok, cancel_claim} = Custody.claim_next("worker:cancel-succeeded-create", 60)
    assert {:ok, execution} = Executor.run(cancel_claim, options(fake))

    assert execution.status == :cancelled
    assert execution.remote_session_id == remote_session["id"]
    assert execution.remote_turn_id == nil
    assert FakeAPI.state(fake).session["state"] == "closed"
  end

  test "stop distinguishes a failed create with no resource from an uncertain create" do
    failed = claim_episode!("cancel-failed-create-journal")
    {:ok, failed_fake} = fake_for(failed, [reply("unused")])

    assert :ok =
             prepare_remote_operation(failed, :create_session, create_key(failed), nil, fn ->
               FakeAPI.seed_operation(
                 failed_fake,
                 create_key(failed),
                 failed_operation("repository_unavailable", "CreateRemoteSession")
               )

               :ok
             end)

    assert {:ok, _requested} =
             Custody.request_cancel(
               failed.episode.id,
               failed.episode.key,
               failed.turn.turn_ref,
               "cancel:failed-create:#{failed.turn.id}",
               "Stop after Coop proved no session was created."
             )

    assert {:ok, failed_claim} = Custody.claim_next("worker:cancel-failed-create", 60)
    assert {:ok, failed_execution} = Executor.run(failed_claim, options(failed_fake))
    assert failed_execution.status == :cancelled
    assert failed_execution.remote_session_id == nil
    assert failed_execution.remote_turn_id == nil
    assert FakeAPI.state(failed_fake).create_count == 0

    uncertain = claim_episode!("cancel-uncertain-create-journal")
    {:ok, uncertain_fake} = fake_for(uncertain, [reply("unused")])
    uncertainty = uncertain_operation("operation_uncertain", "CreateRemoteSession")

    assert :ok =
             prepare_remote_operation(
               uncertain,
               :create_session,
               create_key(uncertain),
               nil,
               fn ->
                 FakeAPI.seed_operation(uncertain_fake, create_key(uncertain), uncertainty)
                 :ok
               end
             )

    assert {:ok, _requested} =
             Custody.request_cancel(
               uncertain.episode.id,
               uncertain.episode.key,
               uncertain.turn.turn_ref,
               "cancel:uncertain-create:#{uncertain.turn.id}",
               "Keep custody until Coop proves the create outcome."
             )

    assert {:ok, uncertain_claim} = Custody.claim_next("worker:cancel-uncertain-create", 60)

    assert Executor.run(uncertain_claim, options(uncertain_fake)) ==
             {:error,
              {:work_cancellation_unresolved,
               {:coop_operation_uncertain, "operation_uncertain", "simulated operation_uncertain"}}}
  end

  test "confirmed, uncertain, and still-running session creation have distinct custody" do
    failed_claim = claim_episode!("create-failed")
    {:ok, failed_fake} = FakeAPI.start_link([reply("unused")])

    FakeAPI.seed_operation(
      failed_fake,
      create_key(failed_claim),
      failed_operation("no_capacity", "CreateRemoteSession")
    )

    assert {:error,
            {:work_generation_spent, :session_create,
             {:coop_operation_failed, "no_capacity", _detail}}} =
             Executor.run(failed_claim, options(failed_fake))

    assert Responder.Repo.get!(Responder.Work.Session, failed_claim.session.id).create_generation ==
             2

    uncertain_claim = claim_episode!("create-uncertain")
    {:ok, uncertain_fake} = FakeAPI.start_link([reply("unused")])

    FakeAPI.seed_operation(
      uncertain_fake,
      create_key(uncertain_claim),
      uncertain_operation("operation_uncertain", "CreateRemoteSession")
    )

    assert {:error,
            {:work_execution_blocked, {:coop_operation_uncertain, "operation_uncertain", _detail}}} =
             Executor.run(uncertain_claim, options(uncertain_fake))

    running_claim = claim_episode!("create-running")
    {:ok, running_fake} = FakeAPI.start_link([reply("unused")])

    FakeAPI.seed_operation(
      running_fake,
      create_key(running_claim),
      running_operation("CreateRemoteSession")
    )

    assert Executor.run(running_claim, Keyword.put(options(running_fake), :max_polls, 1)) ==
             {:error, {:work_poll_window_elapsed, :operation}}
  end

  test "a new logical turn rotates an exhausted Coop session before freezing its briefing" do
    claim = claim_with_bound_empty_session!("exhausted-session-rotation")
    {:ok, fake} = fake_for(claim, [reply("The replacement session completed the work.")])

    FakeAPI.update(fake, fn state ->
      %{state | session: Map.put(state.session, "state", "exhausted")}
    end)

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted

    sessions =
      Responder.Repo.all(
        from(session in Responder.Work.Session,
          where: session.episode_id == ^claim.episode.id,
          order_by: [asc: session.generation]
        )
      )

    assert Enum.map(sessions, & &1.generation) == [1, 2]
    assert List.last(sessions).coop_session_id =~ ":replacement:1"

    persisted_turn = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted_turn.session_id == List.last(sessions).id
    assert persisted_turn.submission["context"]["mode"] == "full"
  end

  test "a bound turn remains pollable after its immutable session becomes exhausted" do
    claim = bound_turn!("bound-turn-exhausted-session")
    {:ok, fake} = fake_for(claim, [])

    FakeAPI.update(fake, fn state ->
      session = Map.put(state.session, "state", "exhausted")

      turn = %{
        "id" => claim.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => claim.session.coop_session_id,
        "state" => "running"
      }

      %{state | session: session, turn: turn}
    end)

    assert Executor.run(claim, Keyword.put(options(fake), :max_polls, 1)) ==
             {:error, {:work_poll_window_elapsed, :turn}}

    assert FakeAPI.state(fake).submit_count == 0
  end

  test "remote session and turn resources must match their pinned local identity" do
    wrong_session = claim_with_bound_empty_session!("wrong-session-identity")
    {:ok, wrong_session_fake} = fake_for(wrong_session, [reply("unused")])

    change_session_id = fn fallback ->
      {:ok, session} = fallback.()
      {:ok, Map.put(session, "id", "remote:another-episode")}
    end

    assert Executor.run(
             wrong_session,
             protocol_options(wrong_session_fake, %{get_session: change_session_id})
           ) == {:error, {:coop_protocol_error, :session_identity}}

    wrong_authority = claim_with_bound_empty_session!("wrong-session-authority")
    {:ok, wrong_authority_fake} = fake_for(wrong_authority, [reply("unused")])

    change_policy_digest = fn fallback ->
      {:ok, session} = fallback.()
      {:ok, Map.put(session, "policy_digest", String.duplicate("f", 64))}
    end

    assert Executor.run(
             wrong_authority,
             protocol_options(wrong_authority_fake, %{get_session: change_policy_digest})
           ) == {:error, {:coop_protocol_error, :session_authority}}

    wrong_turn_session = bound_turn!("wrong-turn-session")
    {:ok, wrong_turn_session_fake} = fake_for(wrong_turn_session, [])

    FakeAPI.seed_turn(
      wrong_turn_session_fake,
      wrong_turn_session.session.coop_session_id,
      wrong_turn_session.turn.coop_turn_id,
      "running"
    )

    change_turn_session = fn fallback ->
      {:ok, turn} = fallback.()
      {:ok, Map.put(turn, "session_id", "remote:another-session")}
    end

    assert Executor.run(
             wrong_turn_session,
             protocol_options(wrong_turn_session_fake, %{get_turn: change_turn_session})
           ) == {:error, {:coop_protocol_error, :turn_session_identity}}

    wrong_turn = bound_turn!("wrong-turn-identity")
    {:ok, wrong_turn_fake} = fake_for(wrong_turn, [])

    FakeAPI.seed_turn(
      wrong_turn_fake,
      wrong_turn.session.coop_session_id,
      wrong_turn.turn.coop_turn_id,
      "running"
    )

    change_turn_id = fn fallback ->
      {:ok, turn} = fallback.()
      {:ok, Map.put(turn, "id", "remote:another-turn")}
    end

    assert Executor.run(
             wrong_turn,
             protocol_options(wrong_turn_fake, %{get_turn: change_turn_id})
           ) == {:error, {:coop_protocol_error, :turn_identity}}
  end

  test "a submit revision conflict spends only the submit generation" do
    claim = claim_with_bound_session!("submit-conflict")
    {:ok, fake} = fake_for(claim, [reply("unused")])

    FakeAPI.seed_operation(
      fake,
      turn_key(claim),
      failed_operation("revision_conflict", "SubmitTurn")
    )

    assert {:error,
            {:work_generation_spent, :turn_submit,
             {:coop_operation_failed, "revision_conflict", _detail}}} =
             Executor.run(claim, options(fake))

    reloaded = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert reloaded.submit_generation == 2
    assert reloaded.coop_turn_id == nil
    assert reloaded.submission == claim.turn.submission
  end

  test "terminal and unknown remote turn states are never silently replayed" do
    Enum.each(~w(failed interrupted budget_exhausted cancelled), fn state ->
      work = bound_turn!("terminal-#{state}")
      {:ok, fake} = fake_for(work, [])
      FakeAPI.seed_turn(fake, work.session.coop_session_id, work.turn.coop_turn_id, state)

      assert {:error, {:work_turn_terminal, ^state, nil, nil}} =
               Executor.run(work, options(fake))

      assert FakeAPI.state(fake).submit_count == 0
    end)

    unknown = bound_turn!("unknown-state")
    {:ok, fake} = fake_for(unknown, [])
    FakeAPI.seed_turn(fake, unknown.session.coop_session_id, unknown.turn.coop_turn_id, "paused")

    assert Executor.run(unknown, options(fake)) ==
             {:error, {:coop_protocol_error, :turn_state}}
  end

  test "a queued remote turn has a bounded wait and renews a long-lived local lease" do
    work = bound_turn!("queued-timeout")
    {:ok, fake} = fake_for(work, [])
    FakeAPI.seed_turn(fake, work.session.coop_session_id, work.turn.coop_turn_id, "queued")

    counter = start_supervised!({Agent, fn -> 0 end})

    monotonic = fn -> Agent.get_and_update(counter, fn value -> {value, value + 25_000} end) end

    assert Executor.run(
             work,
             options(fake)
             |> Keyword.put(:lease_seconds, 60)
             |> Keyword.put(:max_polls, 1)
             |> Keyword.put(:monotonic_ms, monotonic)
           ) == {:error, {:work_poll_window_elapsed, :turn}}

    reloaded = Responder.Repo.get!(Responder.Work.Turn, work.turn.id)
    assert reloaded.lease_ref == work.lease_ref
    assert DateTime.compare(reloaded.lease_expires_at, work.turn.lease_expires_at) in [:gt, :eq]
  end

  test "malformed candidate and completed receipts stop at the Coop protocol boundary" do
    malformed = bound_turn!("malformed-candidate")
    {:ok, malformed_fake} = fake_for(malformed, [])

    FakeAPI.update(malformed_fake, fn state ->
      turn = %{
        "candidate" => %{
          "attempt" => 1,
          "message" => reply("Wrong digest."),
          "sha256" => String.duplicate("0", 64)
        },
        "id" => malformed.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => malformed.session.coop_session_id,
        "state" => "awaiting_validation"
      }

      %{state | turn: turn}
    end)

    assert Executor.run(malformed, options(malformed_fake)) ==
             {:error, {:coop_protocol_error, :candidate_digest}}

    completed = accepted_intent_turn!("missing-receipt")
    {:ok, completed_fake} = fake_for(completed, [])

    FakeAPI.update(completed_fake, fn state ->
      turn = %{
        "assistant_message" => completed.turn.candidate,
        "id" => completed.turn.coop_turn_id,
        "revision" => 2,
        "session_id" => completed.session.coop_session_id,
        "state" => "completed",
        "validation_attempt" => completed.turn.candidate_attempt,
        "validation_candidate_sha256" => completed.turn.candidate_sha256
      }

      %{state | turn: turn}
    end)

    assert Executor.run(completed, options(completed_fake)) ==
             {:error, {:coop_protocol_error, :validation_receipt}}
  end

  test "a completed receipt belongs to the exact staged candidate attempt" do
    claim = accepted_intent_turn!("stale-completed-attempt", 2)
    {:ok, fake} = fake_for(claim, [])

    FakeAPI.update(fake, fn state ->
      completed = %{
        "assistant_message" => claim.turn.candidate,
        "id" => claim.turn.coop_turn_id,
        "session_id" => claim.session.coop_session_id,
        "state" => "completed",
        "validation_attempt" => 1,
        "validation_candidate_sha256" => claim.turn.candidate_sha256,
        "validation_receipt" => "validation:stale-attempt"
      }

      %{state | turn: completed}
    end)

    assert Executor.run(claim, options(fake)) ==
             {:error, {:coop_protocol_error, :validation_attempt}}

    persisted = Responder.Repo.get!(Responder.Work.Turn, claim.turn.id)
    assert persisted.status == :pending
    assert persisted.result_ref == nil
  end

  test "invalid validation context fails locally before Coop is mutated" do
    Enum.each(
      [fn _claim -> :invalid end, fn _claim -> {:error, :context_unavailable} end],
      fn validation_context ->
        claim = claim_episode!("bad-context-#{System.unique_integer([:positive])}")
        {:ok, fake} = FakeAPI.start_link([reply("Must not be validated.")])

        FakeAPI.update(fake, fn state ->
          %{state | session: %{state.session | "id" => "remote:#{claim.episode.id}"}}
        end)

        expected =
          if validation_context.(claim) == :invalid,
            do: {:error, {:invalid_work_executor, :validation_context}},
            else: {:error, :context_unavailable}

        assert Executor.run(
                 claim,
                 Keyword.put(options(fake), :validation_context, validation_context)
               ) == expected

        assert FakeAPI.state(fake).validations == []
      end
    )
  end

  test "remote cancellation failure, uncertainty, and preexisting terminal state are explicit" do
    terminal = cancel_claim!("already-terminal", "completed")
    {:ok, terminal_fake} = fake_for(terminal, [])

    FakeAPI.seed_turn(
      terminal_fake,
      terminal.session.coop_session_id,
      terminal.turn.coop_turn_id,
      "completed"
    )

    assert {:ok, %{status: :cancelled}} = Executor.run(terminal, options(terminal_fake))
    assert FakeAPI.state(terminal_fake).cancel_keys == []

    failed = cancel_claim!("cancel-failed", "running")
    {:ok, failed_fake} = fake_for(failed, [])
    FakeAPI.seed_turn(failed_fake, failed.session.coop_session_id, failed.turn.coop_turn_id)

    FakeAPI.seed_operation(
      failed_fake,
      Cancellation.operation_key(failed.turn.id, 1),
      failed_operation("revision_conflict", "CancelTurn")
    )

    assert {:error,
            {:work_generation_spent, :cancellation,
             {:coop_operation_failed, "revision_conflict", _detail}}} =
             Executor.run(failed, options(failed_fake))

    unresolved = cancel_claim!("cancel-uncertain", "running")
    {:ok, unresolved_fake} = fake_for(unresolved, [])

    FakeAPI.seed_turn(
      unresolved_fake,
      unresolved.session.coop_session_id,
      unresolved.turn.coop_turn_id
    )

    FakeAPI.seed_operation(
      unresolved_fake,
      Cancellation.operation_key(unresolved.turn.id, 1),
      uncertain_operation("operation_uncertain", "CancelTurn")
    )

    assert {:error,
            {:work_cancellation_unresolved,
             {:coop_operation_uncertain, "operation_uncertain", _detail}}} =
             Executor.run(unresolved, options(unresolved_fake))
  end

  test "successful operation journals recover session and turn resources" do
    session_claim = claim_episode!("journal-session")
    {:ok, session_fake} = fake_for(session_claim, [reply("Recovered session operation.")])

    FakeAPI.seed_operation(
      session_fake,
      create_key(session_claim),
      succeeded_operation(
        "CreateRemoteSession",
        "session",
        "remote:#{session_claim.episode.id}"
      )
    )

    assert {:ok, %{status: :accepted}} = Executor.run(session_claim, options(session_fake))
    assert FakeAPI.state(session_fake).create_count == 0

    turn_claim = claim_with_bound_session!("journal-turn")
    {:ok, turn_fake} = fake_for(turn_claim, [reply("Recovered turn operation.")])

    strip_turn = fn fallback ->
      {:ok, %{"operation" => operation, "turn" => _turn}} = fallback.()
      {:ok, %{"operation" => operation}}
    end

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               turn_claim,
               protocol_options(turn_fake, %{submit_turn: strip_turn})
             )

    assert FakeAPI.state(turn_fake).submit_count == 1
  end

  test "a malformed successful mutation response reconciles the exact operation journal" do
    create_claim = claim_episode!("malformed-success-create")
    {:ok, create_fake} = fake_for(create_claim, [reply("Recovered malformed create response.")])

    malformed_after_commit = fn fallback ->
      _committed_response = fallback.()
      {:ok, %{"unexpected" => true}}
    end

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               create_claim,
               protocol_options(create_fake, %{create_session: malformed_after_commit})
             )

    submit_claim = claim_with_bound_session!("malformed-success-submit")
    {:ok, submit_fake} = fake_for(submit_claim, [reply("Recovered malformed submit response.")])

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               submit_claim,
               protocol_options(submit_fake, %{submit_turn: malformed_after_commit})
             )

    validation_claim = claim_episode!("malformed-success-validation")

    {:ok, validation_fake} =
      fake_for(validation_claim, [reply("Recovered malformed validation response.")])

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               validation_claim,
               protocol_options(validation_fake, %{validate_candidate: malformed_after_commit})
             )

    cancellation_claim = cancel_claim!("malformed-success-cancel", "running")
    {:ok, cancellation_fake} = fake_for(cancellation_claim, [])

    FakeAPI.seed_turn(
      cancellation_fake,
      cancellation_claim.session.coop_session_id,
      cancellation_claim.turn.coop_turn_id,
      "running"
    )

    assert {:ok, %{status: :cancelled}} =
             Executor.run(
               cancellation_claim,
               protocol_options(cancellation_fake, %{
                 cancel_turn: malformed_after_commit,
                 close_session: malformed_after_commit
               })
             )
  end

  test "malformed create, submit, and resource envelopes cannot enter durable custody" do
    create_claim = claim_episode!("bad-create-envelope")
    {:ok, create_fake} = fake_for(create_claim, [reply("unused")])

    assert Executor.run(
             create_claim,
             protocol_options(create_fake, %{create_session: {:ok, %{"unexpected" => true}}})
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :create_session, :create_session_response}}

    revision_claim = claim_with_bound_session!("bad-session-revision")
    {:ok, revision_fake} = fake_for(revision_claim, [reply("unused")])

    assert Executor.run(
             revision_claim,
             protocol_options(revision_fake, %{
               get_session:
                 {:ok,
                  %{
                    "external_ref" => revision_claim.session.external_ref,
                    "id" => revision_claim.session.coop_session_id,
                    "policy" => revision_claim.session.policy,
                    "policy_digest" => revision_claim.session.policy_digest,
                    "state" => "open"
                  }}
             })
           ) == {:error, {:coop_protocol_error, :resource_revision}}

    submit_claim = claim_with_bound_session!("bad-submit-envelope")
    {:ok, submit_fake} = fake_for(submit_claim, [reply("unused")])

    assert Executor.run(
             submit_claim,
             protocol_options(submit_fake, %{submit_turn: {:ok, %{"unexpected" => true}}})
           ) ==
             {:error, {:coop_mutation_response_unresolved, :submit_turn, :submit_turn_response}}

    turn_claim = claim_with_bound_session!("bad-turn-resource")
    {:ok, turn_fake} = fake_for(turn_claim, [reply("unused")])

    assert Executor.run(
             turn_claim,
             protocol_options(turn_fake, %{submit_turn: {:ok, %{"turn" => %{}}}})
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :submit_turn,
               {:coop_protocol_error, :turn_resource}}}
  end

  test "direct validation cleanup and uncertainty reconcile the exact remote candidate" do
    cleanup_claim = claim_episode!("direct-cleanup")
    {:ok, cleanup_fake} = fake_for(cleanup_claim, [reply("Cleanup retry.")])

    cleanup_error =
      {:error, {:coop_error, 503, "session_cleanup_error", "cleanup unavailable"}}

    assert {:error,
            {:work_generation_spent, :validation,
             {:coop_error, 503, "session_cleanup_error", "cleanup unavailable"}}} =
             Executor.run(
               cleanup_claim,
               protocol_options(cleanup_fake, %{validate_candidate: cleanup_error})
             )

    uncertain_claim = claim_episode!("direct-validation-uncertain")
    {:ok, uncertain_fake} = fake_for(uncertain_claim, [reply("Uncertain validation.")])

    uncertain_error =
      {:error, {:coop_error, 409, "operation_uncertain", "outcome unknown"}}

    assert {:error,
            {:work_execution_blocked,
             {:coop_error, 409, "operation_uncertain", "outcome unknown"}}} =
             Executor.run(
               uncertain_claim,
               protocol_options(uncertain_fake, %{validate_candidate: uncertain_error})
             )

    malformed_claim = claim_episode!("bad-validation-envelope")
    {:ok, malformed_fake} = fake_for(malformed_claim, [reply("Malformed validation.")])

    assert Executor.run(
             malformed_claim,
             protocol_options(malformed_fake, %{
               validate_candidate: {:ok, %{"unexpected" => true}}
             })
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :validate_candidate, :validation_response}}
  end

  test "an uncertain reject that already resumed the turn keeps the same model turn alive" do
    claim = claim_episode!("uncertain-reject-resumed")

    {:ok, fake} =
      fake_for(claim, [
        silent("This invalid first candidate must be repaired."),
        reply("The repaired answer remains in the same logical turn.")
      ])

    uncertain_after_reject = fn fallback ->
      assert {:ok, %{"turn" => _next_candidate}} = fallback.()

      FakeAPI.update(fake, fn state ->
        %{state | turn: state.turn |> Map.put("candidate", nil) |> Map.put("state", "queued")}
      end)

      {:error, {:coop_error, 409, "operation_uncertain", "response lost after reject"}}
    end

    assert Executor.run(
             claim,
             protocol_options(fake, %{validate_candidate: uncertain_after_reject})
             |> Keyword.put(:max_polls, 1)
           ) == {:error, {:work_poll_window_elapsed, :turn}}

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject]
    assert state.turn["state"] == "queued"
  end

  test "direct cancellation conflicts and uncertain outcomes preserve remote custody" do
    conflict = cancel_claim!("direct-cancel-conflict", "running")
    {:ok, conflict_fake} = fake_for(conflict, [])
    FakeAPI.seed_turn(conflict_fake, conflict.session.coop_session_id, conflict.turn.coop_turn_id)

    conflict_error =
      {:error, {:coop_error, 409, "revision_conflict", "remote advanced"}}

    assert {:error,
            {:work_generation_spent, :cancellation,
             {:coop_error, 409, "revision_conflict", "remote advanced"}}} =
             Executor.run(
               conflict,
               protocol_options(conflict_fake, %{cancel_turn: conflict_error})
             )

    uncertain = cancel_claim!("direct-cancel-uncertain", "running")
    {:ok, uncertain_fake} = fake_for(uncertain, [])

    FakeAPI.seed_turn(
      uncertain_fake,
      uncertain.session.coop_session_id,
      uncertain.turn.coop_turn_id
    )

    uncertain_error =
      {:error, {:coop_error, 409, "operation_uncertain", "outcome unknown"}}

    assert {:error,
            {:work_cancellation_unresolved,
             {:coop_error, 409, "operation_uncertain", "outcome unknown"}}} =
             Executor.run(
               uncertain,
               protocol_options(uncertain_fake, %{cancel_turn: uncertain_error})
             )

    malformed = cancel_claim!("bad-cancel-envelope", "running")
    {:ok, malformed_fake} = fake_for(malformed, [])

    FakeAPI.seed_turn(
      malformed_fake,
      malformed.session.coop_session_id,
      malformed.turn.coop_turn_id
    )

    assert Executor.run(
             malformed,
             protocol_options(malformed_fake, %{cancel_turn: {:ok, %{"unexpected" => true}}})
           ) ==
             {:error, {:coop_mutation_response_unresolved, :cancel_turn, :cancel_turn_response}}
  end

  test "executor rejects unsafe settings and claims without touching work" do
    claim = claim_episode!("invalid-options")
    {:ok, fake} = fake_for(claim, [reply("unused")])
    valid = options(fake)

    cases = [
      {Keyword.put(valid, :api, "module"), :api},
      {Keyword.put(valid, :lease_seconds, 0), :lease_seconds},
      {Keyword.put(valid, :max_block_ms, 20_000), :max_block_ms},
      {Keyword.put(valid, :max_polls, 0), :max_polls},
      {Keyword.put(valid, :monotonic_ms, :clock), :monotonic_ms},
      {Keyword.put(valid, :now, :clock), :now},
      {Keyword.put(valid, :poll_interval_ms, 20_000), :poll_interval_ms},
      {Keyword.put(valid, :sleep, :sleep), :sleep},
      {Keyword.put(valid, :validation_context, :context), :validation_context}
    ]

    Enum.each(cases, fn {invalid, field} ->
      assert Executor.run(claim, invalid) == {:error, {:invalid_work_executor, field}}
    end)

    assert Executor.run(claim, Keyword.put(valid, :unknown, true)) ==
             {:error, {:invalid_work_executor, :options}}

    assert Executor.run(claim, :invalid) == {:error, {:invalid_work_executor, :options}}
    assert Executor.run(%{}, valid) == {:error, {:invalid_work_executor, :claim}}

    delivery = %{claim | turn: %{claim.turn | status: :delivery_pending}}
    assert Executor.run(delivery, valid) == {:error, :work_delivery_requires_gateway}

    settled = %{claim | turn: %{claim.turn | status: :settled}}
    assert Executor.run(settled, valid) == {:error, :work_turn_not_executable}

    malformed_submission = %{claim | turn: %{claim.turn | submission: "not-a-document"}}
    assert Executor.run(malformed_submission, valid) == {:error, :work_submission_missing}

    assert Executor.run(claim, api: FakeAPI) ==
             {:error, {:invalid_work_executor, :options}}
  end

  test "session creation reconciles both operation-only and lost-response outcomes" do
    Enum.each([:operation_only, :lost_response], fn mode ->
      claim = claim_episode!("create-reconcile-#{mode}")
      {:ok, fake} = fake_for(claim, [reply("Recovered create #{mode}.")])

      override = fn fallback ->
        {:ok, %{"operation" => operation, "session" => _session}} = fallback.()

        case mode do
          :operation_only -> {:ok, %{"operation" => operation}}
          :lost_response -> {:error, {:coop_transport_error, :response_lost}}
        end
      end

      assert {:ok, %{status: :accepted}} =
               Executor.run(claim, protocol_options(fake, %{create_session: override}))

      assert FakeAPI.state(fake).create_count == 1
    end)
  end

  test "session and operation protocol failures cannot bind guessed resources" do
    operation_error = claim_episode!("operation-read-error")
    {:ok, operation_fake} = fake_for(operation_error, [reply("unused")])

    assert Executor.run(
             operation_error,
             protocol_options(operation_fake, %{operation_by_key: {:error, :journal_down}})
           ) == {:error, :journal_down}

    bad_session = claim_episode!("bad-session-resource")
    {:ok, session_fake} = fake_for(bad_session, [reply("unused")])

    assert Executor.run(
             bad_session,
             protocol_options(session_fake, %{create_session: {:ok, %{"session" => %{}}}})
           ) ==
             {:error,
              {:coop_mutation_response_unresolved, :create_session,
               {:coop_protocol_error, :session_resource}}}

    bad_operation = claim_episode!("bad-operation-state")
    {:ok, bad_operation_fake} = fake_for(bad_operation, [reply("unused")])

    FakeAPI.seed_operation(
      bad_operation_fake,
      create_key(bad_operation),
      %{"id" => "op-invalid", "state" => "mystery"}
    )

    assert Executor.run(bad_operation, options(bad_operation_fake)) ==
             {:error, {:coop_protocol_error, :operation_state}}
  end

  test "turn submission distinguishes direct conflict, uncertainty, and journal failure" do
    conflict = claim_with_bound_session!("direct-submit-conflict")
    {:ok, conflict_fake} = fake_for(conflict, [reply("unused")])
    conflict_error = {:error, {:coop_error, 409, "revision_conflict", "stale revision"}}

    assert {:error,
            {:work_generation_spent, :turn_submit,
             {:coop_error, 409, "revision_conflict", "stale revision"}}} =
             Executor.run(
               conflict,
               protocol_options(conflict_fake, %{submit_turn: conflict_error})
             )

    uncertain = claim_with_bound_session!("submit-uncertain")
    {:ok, uncertain_fake} = fake_for(uncertain, [reply("unused")])

    FakeAPI.seed_operation(
      uncertain_fake,
      turn_key(uncertain),
      uncertain_operation("operation_uncertain", "SubmitTurn")
    )

    assert {:error,
            {:work_execution_blocked, {:coop_operation_uncertain, "operation_uncertain", _detail}}} =
             Executor.run(uncertain, options(uncertain_fake))

    journal_error = claim_with_bound_session!("submit-journal-error")
    {:ok, journal_fake} = fake_for(journal_error, [reply("unused")])

    assert Executor.run(
             journal_error,
             protocol_options(journal_fake, %{operation_by_key: {:error, :journal_down}})
           ) == {:error, :journal_down}
  end

  test "a restarted validator reuses the exact frozen intent and candidate" do
    claim = accepted_intent_turn!("frozen-intent-resume")
    {:ok, fake} = fake_for(claim, [])

    FakeAPI.update(fake, fn state ->
      turn = %{
        "candidate" => %{
          "attempt" => claim.turn.candidate_attempt,
          "message" => claim.turn.candidate,
          "sha256" => claim.turn.candidate_sha256
        },
        "id" => claim.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => claim.session.coop_session_id,
        "state" => "awaiting_validation"
      }

      %{state | turn: turn}
    end)

    assert {:ok, %{status: :accepted}} = Executor.run(claim, options(fake))
    assert Enum.map(FakeAPI.state(fake).validations, & &1.verdict) == [:accept]

    malformed = bound_turn!("candidate-shape")
    {:ok, malformed_fake} = fake_for(malformed, [])

    FakeAPI.update(malformed_fake, fn state ->
      turn = %{
        "candidate" => %{"attempt" => 1},
        "id" => malformed.turn.coop_turn_id,
        "revision" => 1,
        "session_id" => malformed.session.coop_session_id,
        "state" => "awaiting_validation"
      }

      %{state | turn: turn}
    end)

    assert Executor.run(malformed, options(malformed_fake)) ==
             {:error, {:coop_protocol_error, :candidate}}
  end

  test "a validation-context provider may return its durable snapshot explicitly" do
    claim = claim_episode!("explicit-validation-context")
    {:ok, fake} = fake_for(claim, [reply("Used the supplied host context.")])

    context = %{
      "artifact_refs" => [],
      "records" => %{},
      "visible_reply_required" => true
    }

    assert {:ok, %{status: :accepted}} =
             Executor.run(
               claim,
               Keyword.put(options(fake), :validation_context, fn _claim -> {:ok, context} end)
             )
  end

  defp claim_episode!(suffix) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: "slack:user:U-stage3",
        episode_id: id,
        episode_key: "work-executor:#{suffix}:#{id}",
        native_input_id: "slack-message:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => "Please handle #{suffix}."},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60, :work)
    claim
  end

  defp options(fake) do
    [
      api: FakeAPI,
      client: fake,
      lease_seconds: 60,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      now: fn -> @now end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp bound_turn!(suffix) do
    claim = claim_episode!(suffix)

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, turn} =
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
               "coop-session:#{claim.episode.id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               turn.submit_generation,
               "coop-turn:#{claim.episode.id}"
             )

    %{claim | session: session, turn: turn}
  end

  defp claim_with_bound_session!(suffix) do
    claim = claim_episode!(suffix)
    assert {:ok, submission} = SubmissionBuilder.build(claim)

    assert {:ok, turn} =
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
               "remote:#{claim.episode.id}"
             )

    %{claim | session: session, turn: turn}
  end

  defp claim_with_bound_empty_session!(suffix) do
    claim = claim_episode!(suffix)

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:#{claim.episode.id}"
             )

    %{claim | session: session}
  end

  defp accepted_intent_turn!(suffix, attempt \\ 1) do
    claim = bound_turn!(suffix)
    candidate = reply("Validated answer.")
    sha256 = digest(candidate)

    assert {:ok, _staged_turn} =
             Custody.stage_candidate(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               attempt
             )

    assert {:ok, result} = Result.new(:reply, Jason.decode!(candidate))

    assert {:ok, turn} =
             Custody.prepare_validation(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               sha256,
               attempt,
               :accept,
               result
             )

    %{claim | turn: turn}
  end

  defp cancel_claim!(suffix, _remote_state) do
    work = bound_turn!(suffix)

    assert {:ok, _requested} =
             Custody.request_cancel(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               "cancel:#{work.turn.id}",
               "Stopped by the operator."
             )

    assert {:ok, claim} = Custody.claim_next("worker:cancel:#{suffix}", 60, :work)
    claim
  end

  defp fake_for(claim, candidates, options \\ []) do
    with {:ok, fake} <- FakeAPI.start_link(candidates, options) do
      FakeAPI.update(fake, fn state ->
        session =
          Map.merge(state.session, %{
            "external_ref" => claim.session.external_ref,
            "id" => claim.session.coop_session_id || "remote:#{claim.episode.id}",
            "policy" => claim.session.policy,
            "policy_digest" => claim.session.policy_digest
          })

        %{state | session: session}
      end)

      {:ok, fake}
    end
  end

  defp protocol_options(fake, overrides) do
    options(%{fake: fake, overrides: overrides})
    |> Keyword.put(:api, ProtocolAPI)
  end

  defp prepare_remote_operation(claim, kind, key, revision, function) do
    Custody.with_mutation_fence(
      claim.episode.id,
      claim.turn.turn_ref,
      claim.lease_ref,
      %{
        kind: kind,
        lease_seconds: 60,
        maximum_block_ms: 1_000,
        operation_key: key,
        operation_revision: revision
      },
      function
    )
  end

  defp first_not_found_then(counter, operation) do
    fn _fallback ->
      Agent.get_and_update(counter, fn
        0 -> {:not_found, 1}
        count -> {{:ok, operation}, count + 1}
      end)
    end
  end

  defp reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp silent(reason) do
    Jason.encode!(%{
      "decision_reason" => reason,
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp failed_operation(code, method) do
    %{
      "error_code" => code,
      "error_detail" => "simulated #{code}",
      "id" => "op_failed_#{code}",
      "method" => method,
      "state" => "failed"
    }
  end

  defp uncertain_operation(code, method) do
    %{
      "error_code" => code,
      "error_detail" => "simulated #{code}",
      "id" => "op_uncertain_#{code}",
      "method" => method,
      "state" => "uncertain"
    }
  end

  defp running_operation(method) do
    %{"id" => "op_running", "method" => method, "state" => "running"}
  end

  defp succeeded_operation(method, type, id) do
    %{
      "id" => "op_#{type}_#{id}",
      "method" => method,
      "resource_id" => id,
      "resource_type" => type,
      "state" => "succeeded"
    }
  end

  defp create_key(claim),
    do: "responder:work:create:#{claim.session.id}:g#{claim.session.create_generation}"

  defp turn_key(claim),
    do:
      "responder:work:turn:#{claim.turn.id}:g#{claim.turn.submit_generation}:#{claim.turn.submission_fingerprint}"

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
