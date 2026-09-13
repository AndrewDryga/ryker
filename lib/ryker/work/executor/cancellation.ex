defmodule Ryker.Work.Executor.Cancellation do
  @moduledoc """
  Settles a cancel-pending turn against whatever Coop actually holds.

  A cancellation first fences any session create or turn submit the host
  froze but never confirmed, so a lost response cannot leave an unowned
  remote resource behind. It then cancels a live remote turn under the
  persisted cancel key, closes the session unless the intent transfers it,
  and records a receipt naming the remote state it proved.
  """

  alias Ryker.Work.Cancellation, as: WorkCancellation
  alias Ryker.Work.{Custody, StateBinding}
  alias Ryker.Work.Executor.{Remote, Turns}

  @terminal_turn_states Remote.terminal_turn_states()

  @doc false
  def execute_cancellation(claim, settings) do
    key = WorkCancellation.operation_key(claim.turn.id, claim.turn.cancel_generation)

    with {:ok, claim} <- reconcile_cancellation_session(claim, settings),
         {:ok, claim, remote_turn} <- reconcile_cancellation_turn(claim, settings) do
      continue_cancellation(remote_turn, claim, key, settings)
    end
  end

  defp continue_cancellation(:not_created, claim, _key, settings),
    do: settle_absent_cancellation(claim, settings)

  defp continue_cancellation(%{} = turn, claim, key, settings) do
    if Remote.terminal_turn?(turn),
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
    key = Remote.create_key(claim.session)

    if frozen_remote_operation?(claim.turn, "create_session", key) do
      fence_cancellation_session_create(claim, key, settings)
    else
      {:ok, %{claim | session: %{claim.session | coop_session_id: nil}}}
    end
  end

  defp fence_cancellation_session_create(claim, key, settings) do
    response =
      Remote.mutation_call(settings, :create_session, key, fn ->
        Remote.fence_remote_session(settings, claim, key)
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
    case Remote.operation_resource(
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
    case Remote.api_call(settings, fn -> settings.api.get_session(settings.client, session_id) end) do
      {:ok, remote_session} -> bind_cancellation_session(claim, remote_session)
      {:error, _reason} = error -> error
    end
  end

  defp bind_cancellation_session(claim, %{"id" => session_id} = remote_session)
       when is_binary(session_id) do
    with :ok <-
           Remote.exact_remote_session_state(
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
    with {:ok, remote_turn} <- Remote.fetch_turn(claim, turn_id, settings) do
      {:ok, claim, remote_turn}
    end
  end

  defp reconcile_cancellation_turn(%{turn: %{submission: nil}} = claim, _settings),
    do: {:ok, claim, :not_created}

  defp reconcile_cancellation_turn(claim, settings) do
    key = Remote.turn_key(claim.turn)

    if frozen_remote_operation?(claim.turn, "submit_turn", key) do
      fence_cancellation_turn_submit(claim, key, settings)
    else
      {:ok, claim, :not_created}
    end
  end

  defp fence_cancellation_turn_submit(claim, key, settings) do
    revision = claim.turn.remote_operation_revision

    response =
      with {:ok, artifacts} <- Remote.input_artifacts(claim) do
        Remote.mutation_call(settings, :submit_turn, key, revision, fn ->
          Remote.fence_frozen_turn(settings, claim, key, revision, artifacts)
        end)
      end

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
    case Remote.operation_resource(
           operation,
           "turn",
           "SubmitTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        Turns.fetch_and_bind_turn(claim, turn_id, settings)

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
    case Remote.operation_by_key(settings, key) do
      :not_found -> mutate_cancellation(claim, key, remote_turn, settings)
      {:ok, operation} -> cancellation_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp mutate_cancellation(claim, key, _remote_turn, settings) do
    with {:ok, remote_session} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <- Remote.exact_remote_session(claim.session, remote_session),
         {:ok, observed_revision} <- Remote.revision(remote_session),
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
        Remote.mutation_call(settings, :cancel_turn, key, fn ->
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
    Remote.reconcile_after_transport(
      Remote.ambiguous_mutation(:cancel_turn, reason),
      key,
      settings,
      fn operation -> cancellation_from_operation(claim, operation, key, settings) end
    )
  end

  defp reconcile_cancellation_transport(error, claim, key, settings) do
    case Remote.fetch_bound_turn(claim, settings) do
      {:ok, %{"state" => state} = current} when state in @terminal_turn_states ->
        settle_remote_cancellation(claim, key, current, settings)

      _not_proven ->
        Remote.reconcile_after_transport(error, key, settings, fn operation ->
          cancellation_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp cancellation_from_operation(claim, operation, key, settings) do
    case Remote.operation_resource(
           operation,
           "turn",
           "CancelTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        with {:ok, remote_turn} <- Remote.fetch_turn(claim, turn_id, settings) do
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
    with {:ok, remote_turn} <- Remote.fetch_bound_turn(claim, settings) do
      if Remote.terminal_turn?(remote_turn),
        do: settle_remote_cancellation(claim, key, remote_turn, settings),
        else: {:error, {:work_cancellation_unresolved, reason}}
    end
  end

  defp settle_remote_cancellation(claim, key, %{"state" => state} = remote_turn, settings)
       when state in @terminal_turn_states do
    with :ok <-
           Remote.exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             claim.turn.coop_turn_id,
             StateBinding.binding_digest(claim.turn)
           ),
         {:ok, remote_session} <- fetch_cancellation_session(claim, settings),
         :ok <- Ryker.Accounting.observe_work(claim, remote_turn, remote_session) do
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
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           Remote.exact_remote_session_state(
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

    case Remote.operation_by_key(settings, key) do
      :not_found ->
        mutate_cancellation_close(claim, proof, remote_session, key, settings)

      {:ok, operation} ->
        cancellation_close_from_operation(claim, proof, operation, key, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp mutate_cancellation_close(claim, proof, remote_session, key, settings) do
    with {:ok, observed_revision} <- Remote.revision(remote_session),
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
        Remote.mutation_call(settings, :close_session, key, fn ->
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
             Remote.exact_remote_session_state(
               claim.session,
               remote_session,
               ~w(closed discarded)
             ) do
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
    Remote.reconcile_after_transport(error, key, settings, fn operation ->
      cancellation_close_from_operation(claim, proof, operation, key, settings)
    end)
  end

  defp reconcile_cancellation_close_response(claim, proof, key, reason, settings) do
    Remote.reconcile_after_transport(
      Remote.ambiguous_mutation(:close_session, reason),
      key,
      settings,
      fn operation ->
        cancellation_close_from_operation(claim, proof, operation, key, settings)
      end
    )
  end

  defp cancellation_close_from_operation(claim, proof, operation, key, settings) do
    case Remote.operation_resource(
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
    WorkCancellation.terminal_receipt(
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
    submit_operation_ref =
      if claim.turn.submission == nil, do: nil, else: Remote.turn_key(claim.turn)

    WorkCancellation.absent_receipt(
      Remote.create_key(claim.session),
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

  defp cancellation_close_key(turn),
    do: "ryker:work:cancel-close:#{turn.id}:g#{turn.cancel_generation}"
end
