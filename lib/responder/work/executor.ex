defmodule Responder.Work.Executor do
  @moduledoc """
  Crash-safe execution of one leased episode turn through Coop.

  Every mutating request is keyed from durable Work rows. The exact prompt,
  schema, candidate, and semantic verdict are frozen before their respective
  remote mutations. Lost responses reconcile the operation and remote resource
  rather than spending another model turn.
  """

  alias Responder.Work.{
    Cancellation,
    Custody,
    SubmissionBuilder,
    Validator
  }

  @operation_waiting_states ~w(reserved running)
  @turn_waiting_states ~w(queued starting running)
  @terminal_turn_states ~w(cancelled completed failed interrupted budget_exhausted)

  @spec run(Custody.claim(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(claim, options) do
    with {:ok, settings} <- settings(options),
         :ok <- valid_claim(claim) do
      heartbeat_key = {__MODULE__, claim.turn.id, make_ref()}
      Process.put(heartbeat_key, settings.monotonic_ms.())

      try do
        settings = settings |> Map.put(:heartbeat_key, heartbeat_key) |> Map.put(:claim, claim)

        case claim.turn.status do
          :pending -> execute_turn(claim, settings)
          :cancel_pending -> execute_cancellation(claim, settings)
          :delivery_pending -> {:error, :work_delivery_requires_gateway}
          _other -> {:error, :work_turn_not_executable}
        end
      after
        Process.delete(heartbeat_key)
      end
    end
  end

  defp execute_turn(claim, settings) do
    with {:ok, claim} <- ensure_session(claim, settings),
         {:ok, claim} <- ensure_submission(claim),
         {:ok, claim, remote_turn} <- ensure_turn(claim, settings) do
      await_turn(claim, remote_turn, settings, settings.max_polls)
    end
  end

  defp ensure_submission(%{turn: %{submission: nil}} = claim) do
    with {:ok, submission} <- SubmissionBuilder.build(claim),
         {:ok, turn} <-
           Custody.freeze_submission(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             submission
           ) do
      {:ok, %{claim | turn: turn}}
    end
  end

  defp ensure_submission(%{turn: %{submission: submission}} = claim) when is_map(submission),
    do: {:ok, claim}

  defp ensure_submission(_claim), do: {:error, :work_submission_missing}

  defp ensure_session(%{session: %{coop_session_id: id}} = claim, settings)
       when is_binary(id) do
    with {:ok, remote_session} <-
           api_call(settings, fn -> settings.api.get_session(settings.client, id) end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      use_or_rotate_session(claim, remote_session, settings)
    end
  end

  defp ensure_session(claim, settings) do
    key = create_key(claim.session)

    case operation_by_key(settings, key) do
      :not_found -> create_session(claim, key, settings)
      {:ok, operation} -> bind_session_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp use_or_rotate_session(claim, %{"state" => "open"}, _settings), do: {:ok, claim}

  defp use_or_rotate_session(%{turn: %{coop_turn_id: id}} = claim, _remote, _settings)
       when is_binary(id),
       do: {:ok, claim}

  defp use_or_rotate_session(claim, %{"state" => state}, settings)
       when state in ~w(exhausted closed discarded) do
    with {:ok, rotated} <-
           Custody.rotate_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation
           ) do
      ensure_session(%{claim | session: rotated.session, turn: rotated.turn}, settings)
    end
  end

  defp use_or_rotate_session(_claim, _remote, _settings),
    do: {:error, {:coop_protocol_error, :session_state}}

  defp create_session(claim, key, settings) do
    task = claim.session.external_ref

    case mutation_call(settings, :create_session, key, fn ->
           settings.api.create_session(
             settings.client,
             key,
             claim.session.policy,
             task
           )
         end) do
      {:ok, %{"session" => remote_session}} when is_map(remote_session) ->
        case bind_session(claim, remote_session) do
          {:ok, _claim} = success -> success
          {:error, reason} -> reconcile_create_response(claim, key, reason, settings)
        end

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        bind_session_from_operation(claim, operation, key, settings)

      {:ok, _response} ->
        reconcile_create_response(claim, key, :create_session_response, settings)

      {:error, _reason} = error ->
        reconcile_after_transport(error, key, settings, fn operation ->
          bind_session_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp reconcile_create_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:create_session, reason), key, settings, fn
      operation -> bind_session_from_operation(claim, operation, key, settings)
    end)
  end

  defp bind_session_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "session",
           "CreateRemoteSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} ->
        fetch_and_bind_session(claim, session_id, settings)

      {:confirmed_failed, reason} ->
        with {:ok, _session} <-
               Custody.advance_session_create(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 claim.session.create_generation
               ) do
          {:error, {:work_generation_spent, :session_create, reason}}
        end

      {:uncertain, reason} ->
        {:error, {:work_execution_blocked, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_session(claim, session_id, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn -> settings.api.get_session(settings.client, session_id) end) do
      bind_session(claim, remote_session)
    end
  end

  defp bind_session(claim, %{"id" => remote_session_id} = remote_session)
       when is_binary(remote_session_id) do
    with :ok <- exact_remote_session(claim.session, remote_session),
         {:ok, session} <-
           Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation,
             remote_session_id
           ) do
      {:ok, %{claim | session: session}}
    end
  end

  defp bind_session(_claim, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp ensure_turn(%{turn: %{coop_turn_id: turn_id}} = claim, settings)
       when is_binary(turn_id) do
    with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
      {:ok, claim, remote_turn}
    end
  end

  defp ensure_turn(claim, settings) do
    key = turn_key(claim.turn)

    case operation_by_key(settings, key) do
      :not_found -> submit_turn(claim, key, settings)
      {:ok, operation} -> bind_turn_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp submit_turn(claim, key, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <- exact_remote_session(claim.session, remote_session),
         {:ok, revision} <- revision(remote_session),
         response <-
           mutation_call(settings, :submit_turn, key, revision, fn ->
             settings.api.submit_turn(
               settings.client,
               claim.session.coop_session_id,
               key,
               revision,
               claim.turn.submission["prompt"],
               claim.turn.submission["output_schema"]
             )
           end) do
      handle_submit_response(response, claim, key, settings)
    end
  end

  defp handle_submit_response({:ok, %{"turn" => remote_turn}}, claim, key, settings)
       when is_map(remote_turn) do
    case bind_turn(claim, remote_turn) do
      {:ok, _claim, _turn} = success -> success
      {:error, reason} -> reconcile_submit_response(claim, key, reason, settings)
    end
  end

  defp handle_submit_response({:ok, %{"operation" => operation}}, claim, key, settings)
       when is_map(operation),
       do: bind_turn_from_operation(claim, operation, key, settings)

  defp handle_submit_response({:ok, _response}, claim, key, settings),
    do: reconcile_submit_response(claim, key, :submit_turn_response, settings)

  defp handle_submit_response(
         {:error, {:coop_error, 409, "revision_conflict", _detail} = reason},
         claim,
         _key,
         _settings
       ),
       do: spend_submit_generation(claim, reason)

  defp handle_submit_response({:error, _reason} = error, claim, key, settings) do
    reconcile_after_transport(error, key, settings, fn operation ->
      bind_turn_from_operation(claim, operation, key, settings)
    end)
  end

  defp reconcile_submit_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:submit_turn, reason), key, settings, fn
      operation -> bind_turn_from_operation(claim, operation, key, settings)
    end)
  end

  defp bind_turn_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn",
           "SubmitTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        fetch_and_bind_turn(claim, turn_id, settings)

      {:confirmed_failed, reason} ->
        spend_submit_generation(claim, reason)

      {:uncertain, reason} ->
        {:error, {:work_execution_blocked, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_turn(claim, turn_id, settings) do
    with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
      bind_turn(claim, remote_turn)
    end
  end

  defp bind_turn(claim, %{"id" => remote_turn_id} = remote_turn)
       when is_binary(remote_turn_id) do
    with :ok <- exact_remote_turn(remote_turn, claim.session.coop_session_id, nil),
         {:ok, turn} <-
           Custody.bind_turn(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.turn.submit_generation,
             remote_turn_id
           ) do
      {:ok, %{claim | turn: turn}, remote_turn}
    end
  end

  defp bind_turn(_claim, _remote_turn),
    do: {:error, {:coop_protocol_error, :turn_resource}}

  defp spend_submit_generation(claim, reason) do
    with {:ok, _turn} <-
           Custody.advance_turn_submit(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.submit_generation
           ) do
      {:error, {:work_generation_spent, :turn_submit, reason}}
    end
  end

  defp await_turn(
         claim,
         %{"state" => "awaiting_validation", "candidate" => candidate},
         settings,
         left
       )
       when is_map(candidate) do
    handle_candidate(claim, candidate, settings, left)
  end

  defp await_turn(claim, %{"state" => "completed"} = remote_turn, _settings, _left) do
    accept_completed(claim, remote_turn)
  end

  defp await_turn(claim, %{"state" => state}, settings, left)
       when state in @turn_waiting_states and left > 0 do
    with :ok <- pause(settings),
         {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      await_turn(claim, remote_turn, settings, left - 1)
    end
  end

  defp await_turn(_claim, %{"state" => state}, _settings, 0)
       when state in @turn_waiting_states,
       do: {:error, {:work_poll_window_elapsed, :turn}}

  defp await_turn(_claim, %{"state" => state} = turn, _settings, _left)
       when state in ~w(failed interrupted budget_exhausted cancelled) do
    {:error, {:work_turn_terminal, state, turn["error_code"], turn["error_detail"]}}
  end

  defp await_turn(_claim, _turn, _settings, _left),
    do: {:error, {:coop_protocol_error, :turn_state}}

  defp handle_candidate(claim, candidate, settings, left) do
    with {:ok, message, sha256, attempt} <- candidate_fields(candidate),
         {:ok, turn} <-
           Custody.stage_candidate(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.candidate_sha256,
             claim.turn.candidate_attempt,
             message,
             sha256,
             attempt
           ),
         claim = %{claim | turn: turn},
         {:ok, claim} <- ensure_validation_intent(claim, message, sha256, attempt, settings),
         {:ok, remote_turn} <- validate_candidate(claim, settings) do
      await_turn(claim, remote_turn, settings, left)
    end
  end

  defp ensure_validation_intent(
         %{turn: %{validation_intent: intent}} = claim,
         _message,
         _sha,
         _attempt,
         _settings
       )
       when is_map(intent),
       do: {:ok, claim}

  defp ensure_validation_intent(claim, message, sha256, attempt, settings) do
    with {:ok, validation_context} <- validation_context(claim, settings) do
      case Validator.validate(message, validation_context, settings.now.()) do
        {:accept, %{result: result}} ->
          prepare_validation(claim, sha256, attempt, :accept, result)

        {:reject, violations} ->
          prepare_validation(claim, sha256, attempt, {:reject, violations}, nil)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp prepare_validation(claim, sha256, attempt, verdict, result) do
    with {:ok, turn} <-
           Custody.prepare_validation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             sha256,
             attempt,
             verdict,
             result
           ) do
      {:ok, %{claim | turn: turn}}
    end
  end

  defp validate_candidate(claim, settings) do
    intent = claim.turn.validation_intent
    verdict = validation_verdict(intent)
    key = validation_key(claim.turn, verdict)

    case operation_by_key(settings, key) do
      :not_found -> mutate_validation(claim, key, verdict, settings)
      {:ok, operation} -> validation_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp mutate_validation(claim, key, verdict, settings) do
    case mutation_call(settings, :validate_candidate, key, fn ->
           settings.api.validate_candidate(
             settings.client,
             claim.session.coop_session_id,
             claim.turn.coop_turn_id,
             key,
             claim.turn.candidate_sha256,
             verdict
           )
         end) do
      {:ok, %{"turn" => remote_turn}} when is_map(remote_turn) ->
        case exact_remote_turn(
               remote_turn,
               claim.session.coop_session_id,
               claim.turn.coop_turn_id
             ) do
          :ok -> {:ok, remote_turn}
          {:error, reason} -> reconcile_validation_response(claim, key, reason, settings)
        end

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        validation_from_operation(claim, operation, key, settings)

      {:ok, _response} ->
        reconcile_validation_response(claim, key, :validation_response, settings)

      {:error, {:coop_error, 503, "session_cleanup_error", _detail} = reason} ->
        recover_validation_cleanup(claim, reason, settings)

      {:error, {:coop_error, 409, "operation_uncertain", _detail} = reason} ->
        reconcile_uncertain_validation(claim, reason, settings)

      {:error, _reason} = error ->
        reconcile_after_transport(error, key, settings, fn operation ->
          validation_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp reconcile_validation_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:validate_candidate, reason), key, settings, fn
      operation -> validation_from_operation(claim, operation, key, settings)
    end)
  end

  defp validation_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn_validation",
           "ValidateTurnCandidate",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} when turn_id == claim.turn.coop_turn_id ->
        fetch_bound_turn(claim, settings)

      {:ok, _turn_id} ->
        {:error, {:coop_protocol_error, :turn_identity}}

      {:confirmed_failed, reason} ->
        if validation_cleanup_failure?(reason),
          do: recover_validation_cleanup(claim, reason, settings),
          else: {:error, {:work_execution_blocked, reason}}

      {:uncertain, reason} ->
        reconcile_uncertain_validation(claim, reason, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp spend_validation_generation(claim, reason) do
    with {:ok, _turn} <-
           Custody.advance_validation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.candidate_sha256,
             claim.turn.candidate_attempt,
             claim.turn.validation_generation
           ) do
      {:error, {:work_generation_spent, :validation, reason}}
    end
  end

  defp recover_validation_cleanup(claim, reason, settings) do
    with {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      recover_validation_state(remote_turn, claim, reason)
    end
  end

  defp recover_validation_state(
         %{"state" => "awaiting_validation", "candidate" => candidate},
         claim,
         reason
       )
       when is_map(candidate) do
    recover_validation_candidate(candidate_fields(candidate), claim, reason)
  end

  defp recover_validation_state(_remote_turn, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp recover_validation_candidate(
         {:ok, _message, sha256, attempt},
         claim,
         reason
       )
       when sha256 == claim.turn.candidate_sha256 and attempt == claim.turn.candidate_attempt,
       do: spend_validation_generation(claim, reason)

  defp recover_validation_candidate(_candidate, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp validation_cleanup_failure?({:coop_operation_failed, "session_cleanup_error", _detail}),
    do: true

  defp validation_cleanup_failure?(_reason), do: false

  defp reconcile_uncertain_validation(claim, reason, settings) do
    with {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      uncertain_validation_state(remote_turn, claim, reason)
    end
  end

  defp uncertain_validation_state(%{"state" => "completed"} = turn, _claim, _reason),
    do: {:ok, turn}

  defp uncertain_validation_state(
         %{"state" => "awaiting_validation", "candidate" => candidate} = turn,
         claim,
         reason
       )
       when is_map(candidate) do
    uncertain_validation_candidate(candidate_fields(candidate), turn, claim, reason)
  end

  defp uncertain_validation_state(
         %{"state" => state} = turn,
         %{turn: %{validation_intent: %{"verdict" => "reject"}}},
         _reason
       )
       when state in @turn_waiting_states,
       do: {:ok, turn}

  defp uncertain_validation_state(%{"state" => state} = turn, _claim, _reason)
       when state in @terminal_turn_states,
       do: {:ok, turn}

  defp uncertain_validation_state(_turn, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp uncertain_validation_candidate(
         {:ok, _message, sha256, attempt},
         turn,
         claim,
         _reason
       )
       when sha256 != claim.turn.candidate_sha256 or attempt != claim.turn.candidate_attempt,
       do: {:ok, turn}

  defp uncertain_validation_candidate(_candidate, _turn, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp accept_completed(claim, remote_turn) do
    with {:ok, message, sha256, attempt, receipt} <- completed_fields(remote_turn),
         :ok <- completed_matches(claim.turn, message, sha256, attempt),
         {:ok, accepted} <-
           Custody.accept_result(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             sha256,
             claim.turn.candidate_attempt,
             receipt
           ) do
      {:ok,
       %{
         episode: accepted.episode,
         remote_session_id: claim.session.coop_session_id,
         remote_turn_id: claim.turn.coop_turn_id,
         status: :accepted,
         turn: accepted.turn
       }}
    end
  end

  defp completed_matches(turn, message, sha256, attempt) do
    cond do
      turn.validation_intent == nil or turn.validation_intent["verdict"] != "accept" ->
        {:error, {:coop_protocol_error, :completed_without_accept_intent}}

      turn.candidate_attempt != attempt ->
        {:error, {:coop_protocol_error, :validation_attempt}}

      turn.candidate != message or turn.candidate_sha256 != sha256 ->
        {:error, {:coop_protocol_error, :validated_candidate_mismatch}}

      true ->
        :ok
    end
  end

  defp execute_cancellation(claim, settings) do
    key = Cancellation.operation_key(claim.turn.id, claim.turn.cancel_generation)

    with {:ok, claim} <- reconcile_cancellation_session(claim, settings),
         {:ok, claim, remote_turn} <- reconcile_cancellation_turn(claim, settings) do
      continue_cancellation(remote_turn, claim, key, settings)
    end
  end

  defp continue_cancellation(:not_created, claim, _key, settings),
    do: settle_absent_cancellation(claim, settings)

  defp continue_cancellation(%{} = turn, claim, key, settings) do
    if terminal_turn?(turn),
      do: settle_remote_cancellation(claim, nil, turn, settings),
      else: cancel_remote_turn(claim, key, turn, settings)
  end

  defp reconcile_cancellation_session(
         %{session: %{coop_session_id: session_id}} = claim,
         _settings
       )
       when is_binary(session_id),
       do: {:ok, claim}

  defp reconcile_cancellation_session(claim, settings) do
    key = create_key(claim.session)

    if frozen_remote_operation?(claim.turn, "create_session", key) do
      fence_cancellation_session_create(claim, key, settings)
    else
      {:ok, %{claim | session: %{claim.session | coop_session_id: nil}}}
    end
  end

  defp fence_cancellation_session_create(claim, key, settings) do
    response =
      mutation_call(settings, :create_session, key, fn ->
        settings.api.fence_create_session(
          settings.client,
          key,
          claim.session.policy,
          claim.session.external_ref
        )
      end)

    case response do
      {:ok, operation} when is_map(operation) ->
        cancellation_session_from_operation(claim, operation, key, settings)

      {:error, {:coop_error, 409, "idempotency_conflict", _detail} = reason} ->
        {:error, {:work_cancellation_unresolved, {:fence_idempotency_conflict, reason}}}

      unresolved ->
        {:error, {:work_cancellation_unresolved, {:session_create_fence, unresolved}}}
    end
  end

  defp cancellation_session_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "session",
           "CreateRemoteSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} ->
        fetch_and_bind_cancellation_session(claim, session_id, settings)

      {:confirmed_failed, _reason} ->
        {:ok, %{claim | session: %{claim.session | coop_session_id: nil}}}

      {:uncertain, reason} ->
        {:error, {:work_cancellation_unresolved, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_cancellation_session(claim, session_id, settings) do
    case api_call(settings, fn -> settings.api.get_session(settings.client, session_id) end) do
      {:ok, remote_session} -> bind_cancellation_session(claim, remote_session)
      {:error, _reason} = error -> error
    end
  end

  defp bind_cancellation_session(claim, %{"id" => session_id} = remote_session)
       when is_binary(session_id) do
    with :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ),
         {:ok, session} <-
           Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation,
             session_id
           ) do
      {:ok, %{claim | session: session}}
    end
  end

  defp bind_cancellation_session(_claim, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp reconcile_cancellation_turn(%{session: %{coop_session_id: nil}} = claim, _settings),
    do: {:ok, claim, :not_created}

  defp reconcile_cancellation_turn(
         %{turn: %{coop_turn_id: turn_id}} = claim,
         settings
       )
       when is_binary(turn_id) do
    with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
      {:ok, claim, remote_turn}
    end
  end

  defp reconcile_cancellation_turn(%{turn: %{submission: nil}} = claim, _settings),
    do: {:ok, claim, :not_created}

  defp reconcile_cancellation_turn(claim, settings) do
    key = turn_key(claim.turn)

    if frozen_remote_operation?(claim.turn, "submit_turn", key) do
      fence_cancellation_turn_submit(claim, key, settings)
    else
      {:ok, claim, :not_created}
    end
  end

  defp fence_cancellation_turn_submit(claim, key, settings) do
    revision = claim.turn.remote_operation_revision

    response =
      mutation_call(settings, :submit_turn, key, revision, fn ->
        settings.api.fence_submit_turn(
          settings.client,
          claim.session.coop_session_id,
          key,
          revision,
          claim.turn.submission["prompt"],
          claim.turn.submission["output_schema"]
        )
      end)

    case response do
      {:ok, operation} when is_map(operation) ->
        cancellation_turn_from_operation(claim, operation, key, settings)

      {:error, {:coop_error, 409, "idempotency_conflict", _detail} = reason} ->
        {:error, {:work_cancellation_unresolved, {:fence_idempotency_conflict, reason}}}

      unresolved ->
        {:error, {:work_cancellation_unresolved, {:turn_submit_fence, unresolved}}}
    end
  end

  defp cancellation_turn_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn",
           "SubmitTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        fetch_and_bind_turn(claim, turn_id, settings)

      {:confirmed_failed, _reason} ->
        {:ok, claim, :not_created}

      {:uncertain, reason} ->
        {:error, {:work_cancellation_unresolved, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp frozen_remote_operation?(turn, kind, key),
    do: turn.remote_operation_kind == kind and turn.remote_operation_key == key

  defp cancel_remote_turn(claim, key, remote_turn, settings) do
    case operation_by_key(settings, key) do
      :not_found -> mutate_cancellation(claim, key, remote_turn, settings)
      {:ok, operation} -> cancellation_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp mutate_cancellation(claim, key, _remote_turn, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <- exact_remote_session(claim.session, remote_session),
         {:ok, observed_revision} <- revision(remote_session),
         {:ok, turn} <-
           Custody.freeze_cancellation_revision(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             :cancel_turn,
             observed_revision
           ) do
      revision = turn.cancel_expected_revision

      response =
        mutation_call(settings, :cancel_turn, key, fn ->
          settings.api.cancel_turn(
            settings.client,
            claim.session.coop_session_id,
            claim.turn.coop_turn_id,
            key,
            revision
          )
        end)

      handle_cancellation_response(response, claim, key, settings)
    end
  end

  defp handle_cancellation_response(
         {:ok, %{"turn" => cancelled}},
         claim,
         key,
         settings
       )
       when is_map(cancelled) do
    case settle_remote_cancellation(claim, key, cancelled, settings) do
      {:ok, _execution} = success -> success
      {:error, reason} -> reconcile_cancellation_response(claim, key, reason, settings)
    end
  end

  defp handle_cancellation_response(
         {:ok, %{"operation" => operation}},
         claim,
         key,
         settings
       )
       when is_map(operation),
       do: cancellation_from_operation(claim, operation, key, settings)

  defp handle_cancellation_response({:ok, _response}, claim, key, settings),
    do: reconcile_cancellation_response(claim, key, :cancel_turn_response, settings)

  defp handle_cancellation_response(
         {:error, {:coop_error, 409, "revision_conflict", _detail} = reason},
         claim,
         _key,
         _settings
       ),
       do: spend_cancellation_generation(claim, reason)

  defp handle_cancellation_response(
         {:error, {:coop_error, 409, "operation_uncertain", _detail} = reason},
         claim,
         key,
         settings
       ),
       do: reconcile_uncertain_cancellation(claim, key, reason, settings)

  defp handle_cancellation_response({:error, _reason} = error, claim, key, settings),
    do: reconcile_cancellation_transport(error, claim, key, settings)

  defp reconcile_cancellation_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:cancel_turn, reason), key, settings, fn
      operation -> cancellation_from_operation(claim, operation, key, settings)
    end)
  end

  defp reconcile_cancellation_transport(error, claim, key, settings) do
    case fetch_bound_turn(claim, settings) do
      {:ok, %{"state" => state} = current} when state in @terminal_turn_states ->
        settle_remote_cancellation(claim, key, current, settings)

      _not_proven ->
        reconcile_after_transport(error, key, settings, fn operation ->
          cancellation_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp cancellation_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn",
           "CancelTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
          settle_remote_cancellation(claim, key, remote_turn, settings)
        end

      {:confirmed_failed, reason} ->
        spend_cancellation_generation(claim, reason)

      {:uncertain, reason} ->
        reconcile_uncertain_cancellation(claim, key, reason, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_uncertain_cancellation(claim, key, reason, settings) do
    with {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      if terminal_turn?(remote_turn),
        do: settle_remote_cancellation(claim, key, remote_turn, settings),
        else: {:error, {:work_cancellation_unresolved, reason}}
    end
  end

  defp settle_remote_cancellation(claim, key, %{"state" => state} = remote_turn, settings)
       when state in @terminal_turn_states do
    with :ok <-
           exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             claim.turn.coop_turn_id
           ),
         {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
      finish_cancellation_session(
        claim,
        {:terminal, key, remote_turn},
        remote_session,
        settings
      )
    end
  end

  defp settle_remote_cancellation(_claim, _key, _remote_turn, _settings),
    do: {:error, {:coop_protocol_error, :cancel_turn_not_terminal}}

  defp settle_absent_cancellation(%{session: %{coop_session_id: nil}} = claim, _settings) do
    with {:ok, receipt} <- absent_receipt(claim, nil, nil, nil),
         {:ok, settled} <-
           Custody.settle_cancellation(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok,
       %{
         episode: settled.episode,
         remote_session_id: claim.session.coop_session_id,
         remote_turn_id: nil,
         status: cancellation_status(claim.turn.cancellation_intent),
         turn: settled.turn
       }}
    end
  end

  defp settle_absent_cancellation(claim, settings) do
    with {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
      finish_cancellation_session(claim, :absent, remote_session, settings)
    end
  end

  defp fetch_cancellation_session(claim, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      {:ok, remote_session}
    end
  end

  defp reusable_transfer_session?(%{"action" => "transfer"}, %{"state" => state}),
    do: state == "open"

  defp reusable_transfer_session?(_intent, _session), do: false

  defp finish_cancellation_session(claim, proof, remote_session, settings) do
    cond do
      reusable_transfer_session?(claim.turn.cancellation_intent, remote_session) ->
        settle_cancellation_proof(claim, proof, remote_session, nil)

      remote_session["state"] in ~w(closed discarded) ->
        settle_cancellation_proof(claim, proof, remote_session, nil)

      true ->
        close_cancellation_session(claim, proof, remote_session, settings)
    end
  end

  defp close_cancellation_session(
         claim,
         proof,
         %{"state" => state} = remote_session,
         _settings
       )
       when state in ~w(closed discarded),
       do: settle_cancellation_proof(claim, proof, remote_session, nil)

  defp close_cancellation_session(claim, proof, remote_session, settings) do
    key = cancellation_close_key(claim.turn)

    case operation_by_key(settings, key) do
      :not_found ->
        mutate_cancellation_close(claim, proof, remote_session, key, settings)

      {:ok, operation} ->
        cancellation_close_from_operation(claim, proof, operation, key, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp mutate_cancellation_close(claim, proof, remote_session, key, settings) do
    with {:ok, observed_revision} <- revision(remote_session),
         {:ok, turn} <-
           Custody.freeze_cancellation_revision(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             :close_session,
             observed_revision
           ) do
      revision = turn.close_expected_revision

      response =
        mutation_call(settings, :close_session, key, fn ->
          settings.api.close_session(
            settings.client,
            claim.session.coop_session_id,
            key,
            revision
          )
        end)

      handle_cancellation_close_response(response, claim, proof, key, settings)
    end
  end

  defp handle_cancellation_close_response(
         {:ok, %{"session" => remote_session}},
         claim,
         proof,
         key,
         settings
       )
       when is_map(remote_session) do
    result =
      with :ok <-
             exact_remote_session_state(claim.session, remote_session, ~w(closed discarded)) do
        settle_cancellation_proof(claim, proof, remote_session, key)
      end

    case result do
      {:ok, _execution} = success ->
        success

      {:error, reason} ->
        reconcile_cancellation_close_response(claim, proof, key, reason, settings)
    end
  end

  defp handle_cancellation_close_response(
         {:ok, %{"operation" => operation}},
         claim,
         proof,
         key,
         settings
       )
       when is_map(operation),
       do: cancellation_close_from_operation(claim, proof, operation, key, settings)

  defp handle_cancellation_close_response({:ok, _response}, claim, proof, key, settings),
    do:
      reconcile_cancellation_close_response(
        claim,
        proof,
        key,
        :close_session_response,
        settings
      )

  defp handle_cancellation_close_response(
         {:error, {:coop_error, 409, "revision_conflict", _detail} = reason},
         claim,
         _proof,
         _key,
         _settings
       ),
       do: spend_cancellation_generation(claim, reason)

  defp handle_cancellation_close_response(
         {:error, {:coop_error, 409, "operation_uncertain", _detail} = reason},
         claim,
         proof,
         key,
         settings
       ),
       do: reconcile_uncertain_close(claim, proof, key, reason, settings)

  defp handle_cancellation_close_response(
         {:error, _reason} = error,
         claim,
         proof,
         key,
         settings
       ) do
    reconcile_after_transport(error, key, settings, fn operation ->
      cancellation_close_from_operation(claim, proof, operation, key, settings)
    end)
  end

  defp reconcile_cancellation_close_response(claim, proof, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:close_session, reason), key, settings, fn
      operation -> cancellation_close_from_operation(claim, proof, operation, key, settings)
    end)
  end

  defp cancellation_close_from_operation(claim, proof, operation, key, settings) do
    case operation_resource(
           operation,
           "session",
           "CloseSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} when session_id == claim.session.coop_session_id ->
        with {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
          settle_closed_cancellation_session(
            remote_session,
            claim,
            proof,
            key,
            :session_not_closed
          )
        end

      {:ok, _session_id} ->
        {:error, {:coop_protocol_error, :session_identity}}

      {:confirmed_failed, reason} ->
        spend_cancellation_generation(claim, reason)

      {:uncertain, reason} ->
        reconcile_uncertain_close(claim, proof, key, reason, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_uncertain_close(claim, proof, key, reason, settings) do
    with {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
      settle_closed_cancellation_session(remote_session, claim, proof, key, reason)
    end
  end

  defp settle_closed_cancellation_session(remote_session, claim, proof, key, unresolved) do
    if remote_session["state"] in ~w(closed discarded),
      do: settle_cancellation_proof(claim, proof, remote_session, key),
      else: {:error, {:work_cancellation_unresolved, unresolved}}
  end

  defp settle_cancellation_proof(claim, proof, remote_session, close_operation_ref) do
    with {:ok, receipt} <- cancellation_receipt(claim, proof, remote_session, close_operation_ref),
         {:ok, settled} <-
           Custody.settle_cancellation(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok,
       %{
         episode: settled.episode,
         remote_session_id: remote_session["id"],
         remote_turn_id: remote_turn_id(proof),
         status: cancellation_status(claim.turn.cancellation_intent),
         turn: settled.turn
       }}
    end
  end

  defp cancellation_receipt(claim, :absent, remote_session, close_operation_ref) do
    absent_receipt(
      claim,
      remote_session["id"],
      remote_session["state"],
      close_operation_ref
    )
  end

  defp cancellation_receipt(
         claim,
         {:terminal, cancel_operation_ref, remote_turn},
         remote_session,
         close_operation_ref
       ) do
    Cancellation.terminal_receipt(
      claim.session.coop_session_id,
      claim.turn.coop_turn_id,
      remote_turn["state"],
      cancel_operation_ref,
      remote_session["state"],
      close_operation_ref
    )
  end

  defp remote_turn_id(:absent), do: nil
  defp remote_turn_id({:terminal, _operation_ref, remote_turn}), do: remote_turn["id"]

  defp cancellation_status(%{"action" => "cancel"}), do: :cancelled
  defp cancellation_status(%{"action" => "transfer"}), do: :transferred
  defp cancellation_status(%{"action" => "block"}), do: :blocked

  defp absent_receipt(claim, remote_session_id, session_state, close_operation_ref) do
    submit_operation_ref = if claim.turn.submission == nil, do: nil, else: turn_key(claim.turn)

    Cancellation.absent_receipt(
      create_key(claim.session),
      submit_operation_ref,
      remote_session_id,
      session_state,
      close_operation_ref
    )
  end

  defp spend_cancellation_generation(claim, reason) do
    with {:ok, _turn} <-
           Custody.advance_cancellation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.cancel_generation
           ) do
      {:error, {:work_generation_spent, :cancellation, reason}}
    end
  end

  defp operation_by_key(settings, key) do
    api_call(settings, fn -> settings.api.operation_by_key(settings.client, key) end)
  end

  defp fetch_bound_turn(claim, settings),
    do: fetch_turn(claim, claim.turn.coop_turn_id, settings)

  defp fetch_turn(claim, turn_id, settings) do
    with {:ok, remote_turn} <-
           api_call(settings, fn ->
             settings.api.get_turn(settings.client, claim.session.coop_session_id, turn_id)
           end),
         :ok <- exact_remote_turn(remote_turn, claim.session.coop_session_id, turn_id) do
      {:ok, remote_turn}
    end
  end

  defp operation_resource(
         %{"method" => method, "state" => "succeeded"} = operation,
         type,
         method,
         _key,
         _settings,
         _left
       ) do
    if operation["resource_type"] == type and reference?(operation["resource_id"]),
      do: {:ok, operation["resource_id"]},
      else: {:error, {:coop_protocol_error, :operation_resource}}
  end

  defp operation_resource(
         %{"method" => method, "state" => "failed"} = operation,
         _type,
         method,
         _key,
         _settings,
         _left
       ) do
    {:confirmed_failed,
     {:coop_operation_failed, operation["error_code"] || "failed",
      operation["error_detail"] || "Coop operation failed"}}
  end

  defp operation_resource(
         %{"method" => method, "state" => "uncertain"} = operation,
         _type,
         method,
         _key,
         _settings,
         _left
       ) do
    {:uncertain,
     {:coop_operation_uncertain, operation["error_code"] || "uncertain",
      operation["error_detail"] || "Coop operation outcome is uncertain"}}
  end

  defp operation_resource(
         %{"method" => method, "state" => state},
         type,
         method,
         key,
         settings,
         left
       )
       when state in @operation_waiting_states and left > 0 do
    with :ok <- pause(settings) do
      case operation_by_key(settings, key) do
        {:ok, operation} ->
          operation_resource(operation, type, method, key, settings, left - 1)

        :not_found ->
          {:error, {:coop_protocol_error, :operation_disappeared}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp operation_resource(
         %{"method" => method, "state" => state},
         _type,
         method,
         _key,
         _settings,
         0
       )
       when state in @operation_waiting_states,
       do: {:error, {:work_poll_window_elapsed, :operation}}

  defp operation_resource(
         %{"method" => _actual},
         _type,
         _expected_method,
         _key,
         _settings,
         _left
       ),
       do: {:error, {:coop_protocol_error, :operation_method}}

  defp operation_resource(_operation, _type, _method, _key, _settings, _left),
    do: {:error, {:coop_protocol_error, :operation_state}}

  defp reconcile_after_transport(original_error, key, settings, continuation) do
    case operation_by_key(settings, key) do
      {:ok, operation} -> continuation.(operation)
      :not_found -> original_error
      {:error, _reason} -> original_error
    end
  end

  defp ambiguous_mutation(phase, reason),
    do: {:error, {:coop_mutation_response_unresolved, phase, reason}}

  defp validation_context(claim, settings) do
    case settings.validation_context.(claim) do
      %{} = context -> {:ok, context}
      {:ok, %{} = context} -> {:ok, context}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_work_executor, :validation_context}}
    end
  end

  defp default_validation_context(claim) do
    context = claim.turn.submission["context"]

    %{
      "artifact_refs" => [],
      "records" => %{},
      "visible_reply_required" => visible_reply_required?(context)
    }
  end

  defp visible_reply_required?(%{"mode" => "full", "inputs" => %{"items" => items}}),
    do: Enum.any?(items, &human_input?/1)

  defp visible_reply_required?(%{
         "mode" => "continuation",
         "continuity" => %{"first_input" => first},
         "current_inputs" => %{"items" => items}
       }) do
    human_input?(first) or Enum.any?(items, &human_input?/1)
  end

  defp visible_reply_required?(_context), do: false

  defp human_input?(%{"actor_ref" => actor_ref}) when is_binary(actor_ref),
    do: String.contains?(actor_ref, ":user:")

  defp human_input?(_input), do: false

  defp candidate_fields(%{
         "attempt" => attempt,
         "message" => message,
         "sha256" => sha256
       })
       when is_integer(attempt) and attempt > 0 and is_binary(message) and is_binary(sha256) do
    if digest(message) == sha256,
      do: {:ok, message, sha256, attempt},
      else: {:error, {:coop_protocol_error, :candidate_digest}}
  end

  defp candidate_fields(_candidate), do: {:error, {:coop_protocol_error, :candidate}}

  defp completed_fields(%{
         "assistant_message" => message,
         "validation_attempt" => attempt,
         "validation_candidate_sha256" => sha256,
         "validation_receipt" => receipt
       })
       when is_binary(message) and is_integer(attempt) and attempt > 0 and is_binary(sha256) and
              is_binary(receipt) do
    if digest(message) == sha256 and reference?(receipt),
      do: {:ok, message, sha256, attempt, receipt},
      else: {:error, {:coop_protocol_error, :validation_receipt}}
  end

  defp completed_fields(%{"validation_attempt" => attempt})
       when not is_integer(attempt) or attempt < 1,
       do: {:error, {:coop_protocol_error, :validation_attempt}}

  defp completed_fields(%{"validation_attempt" => _attempt}),
    do: {:error, {:coop_protocol_error, :validation_receipt}}

  defp completed_fields(_turn), do: {:error, {:coop_protocol_error, :validation_attempt}}

  defp validation_verdict(%{"verdict" => "accept"}), do: :accept

  defp validation_verdict(%{"verdict" => "reject", "violations" => violations}),
    do: {:reject, violations}

  defp create_key(session),
    do: "responder:work:create:#{session.id}:g#{session.create_generation}"

  defp turn_key(turn),
    do: "responder:work:turn:#{turn.id}:g#{turn.submit_generation}:#{turn.submission_fingerprint}"

  defp validation_key(turn, verdict) do
    verdict_name = if verdict == :accept, do: "accept", else: "reject"

    "responder:work:validate:#{turn.id}:a#{turn.candidate_attempt}:g#{turn.validation_generation}:#{turn.candidate_sha256}:#{verdict_name}"
  end

  defp cancellation_close_key(turn),
    do: "responder:work:cancel-close:#{turn.id}:g#{turn.cancel_generation}"

  defp revision(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  defp revision(_resource), do: {:error, {:coop_protocol_error, :resource_revision}}

  defp terminal_turn?(%{"state" => state}), do: state in @terminal_turn_states
  defp terminal_turn?(_turn), do: false

  defp exact_remote_session(expected, %{"state" => "open"} = remote_session),
    do: exact_remote_session_state(expected, remote_session, ["open"])

  defp exact_remote_session(_expected, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp exact_remote_session_state(
         expected,
         %{
           "external_ref" => external_ref,
           "id" => id,
           "policy" => policy,
           "policy_digest" => policy_digest,
           "state" => state
         },
         allowed_states
       ) do
    identity_matches = expected.coop_session_id in [nil, id] and reference?(id)

    cond do
      not identity_matches ->
        {:error, {:coop_protocol_error, :session_identity}}

      state not in allowed_states ->
        {:error, {:coop_protocol_error, :session_state}}

      policy != expected.policy or policy_digest != expected.policy_digest or
          external_ref != expected.external_ref ->
        {:error, {:coop_protocol_error, :session_authority}}

      true ->
        :ok
    end
  end

  defp exact_remote_session_state(_expected, _remote_session, _allowed_states),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp exact_remote_turn(
         %{"id" => id, "session_id" => session_id},
         expected_session_id,
         expected_turn_id
       )
       when is_binary(id) and is_binary(session_id) do
    cond do
      session_id != expected_session_id ->
        {:error, {:coop_protocol_error, :turn_session_identity}}

      expected_turn_id != nil and id != expected_turn_id ->
        {:error, {:coop_protocol_error, :turn_identity}}

      not reference?(id) ->
        {:error, {:coop_protocol_error, :turn_identity}}

      true ->
        :ok
    end
  end

  defp exact_remote_turn(_remote_turn, _expected_session_id, _expected_turn_id),
    do: {:error, {:coop_protocol_error, :turn_resource}}

  defp api_call(settings, function) do
    with :ok <- maybe_renew(settings) do
      function.()
    end
  end

  defp mutation_call(settings, kind, key, function),
    do: mutation_call(settings, kind, key, nil, function)

  defp mutation_call(settings, kind, key, revision, function) do
    result =
      Custody.with_mutation_fence(
        settings.claim.episode.id,
        settings.claim.turn.turn_ref,
        settings.claim.lease_ref,
        %{
          kind: kind,
          lease_seconds: settings.lease_seconds,
          maximum_block_ms: settings.max_block_ms,
          operation_key: key,
          operation_revision: revision
        },
        function
      )

    Process.put(settings.heartbeat_key, settings.monotonic_ms.())
    result
  end

  defp pause(settings) do
    settings.sleep.(settings.poll_interval_ms)
    maybe_renew(settings)
  end

  defp maybe_renew(settings) do
    now = settings.monotonic_ms.()
    last = Process.get(settings.heartbeat_key, now)

    if now - last >= settings.heartbeat_interval_ms do
      case Custody.renew(
             settings.claim.episode.id,
             settings.claim.turn.turn_ref,
             settings.claim.lease_ref,
             settings.lease_seconds
           ) do
        {:ok, _turn} ->
          Process.put(settings.heartbeat_key, now)
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  end

  defp settings(options) when is_list(options) do
    allowed = [
      :api,
      :client,
      :lease_seconds,
      :max_block_ms,
      :max_polls,
      :monotonic_ms,
      :now,
      :poll_interval_ms,
      :sleep,
      :validation_context
    ]

    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      validate_settings(%{
        api: Keyword.get(options, :api, Responder.Coop.Client),
        client: Keyword.fetch!(options, :client),
        lease_seconds: Keyword.get(options, :lease_seconds, 300),
        max_block_ms: Keyword.get(options, :max_block_ms, 30_000),
        max_polls: Keyword.get(options, :max_polls, 600),
        monotonic_ms:
          Keyword.get(options, :monotonic_ms, fn ->
            System.monotonic_time(:millisecond)
          end),
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        poll_interval_ms: Keyword.get(options, :poll_interval_ms, 250),
        sleep: Keyword.get(options, :sleep, &Process.sleep/1),
        validation_context:
          Keyword.get(options, :validation_context, &default_validation_context/1)
      })
    else
      {:error, {:invalid_work_executor, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_work_executor, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_work_executor, :options}}

  defp validate_settings(settings) do
    safe_window = div(settings.lease_seconds * 1_000, 3)

    validations = [
      {is_atom(settings.api), :api},
      {is_integer(settings.lease_seconds) and settings.lease_seconds > 0, :lease_seconds},
      {is_integer(settings.max_block_ms) and settings.max_block_ms > 0 and
         settings.max_block_ms < safe_window, :max_block_ms},
      {is_integer(settings.max_polls) and settings.max_polls > 0, :max_polls},
      {is_function(settings.monotonic_ms, 0), :monotonic_ms},
      {is_function(settings.now, 0), :now},
      {is_integer(settings.poll_interval_ms) and settings.poll_interval_ms >= 0 and
         settings.poll_interval_ms < safe_window, :poll_interval_ms},
      {is_function(settings.sleep, 1), :sleep},
      {is_function(settings.validation_context, 1), :validation_context}
    ]

    case Enum.find(validations, fn {valid?, _field} -> not valid? end) do
      nil ->
        {:ok,
         Map.put(settings, :heartbeat_interval_ms, max(div(settings.lease_seconds * 1_000, 3), 1))}

      {_false, field} ->
        {:error, {:invalid_work_executor, field}}
    end
  end

  defp valid_claim(%{
         episode: %{id: episode_id},
         lease_ref: lease_ref,
         session: %{episode_id: episode_id},
         turn: %{episode_id: episode_id, lease_ref: lease_ref}
       })
       when is_binary(episode_id) and is_binary(lease_ref),
       do: :ok

  defp valid_claim(_claim), do: {:error, {:invalid_work_executor, :claim}}

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
