defmodule Ryker.Work.Executor.Turns do
  @moduledoc """
  Submits the frozen turn, awaits it, and finalizes the accepted result.

  `ensure_turn/2` binds the turn under its persisted submit key, reconciling a
  lost response through the operation instead of submitting twice.
  `await_turn/4` polls the remote turn and hands each candidate to
  `Executor.Validation`. On completion the proof is recorded, the selected
  output artifacts are retained, a writable workspace is checkpointed, and the
  result is accepted.
  """

  alias Ryker.Artifacts.Outputs
  alias Ryker.CoopFleet.SessionEvidenceCapture
  alias Ryker.State.Records
  alias Ryker.Work.{Activity, Custody, Measurement, StateBinding, ValidationIntent}
  alias Ryker.Work.Executor.{Remote, Validation}

  @turn_waiting_states Remote.turn_waiting_states()
  @stopped_turn_states Remote.terminal_turn_states() -- ["completed"]

  @doc false
  def ensure_turn(%{turn: %{coop_turn_id: turn_id}} = claim, settings)
      when is_binary(turn_id) do
    with {:ok, remote_turn} <- Remote.fetch_turn(claim, turn_id, settings) do
      {:ok, claim, remote_turn}
    end
  end

  def ensure_turn(claim, settings) do
    key = Remote.turn_key(claim.turn)

    case Remote.operation_by_key(settings, key) do
      :not_found -> submit_turn(claim, key, settings)
      {:ok, operation} -> bind_turn_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp submit_turn(claim, key, settings) do
    with {:ok, artifacts} <- Remote.input_artifacts(claim),
         {:ok, remote_session} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <- Remote.exact_remote_session(claim.session, remote_session),
         {:ok, revision} <- Remote.revision(remote_session),
         :ok <-
           Ryker.Accounting.observe_work(claim, %{"state" => "requested"}, remote_session),
         response <-
           Remote.mutation_call(settings, :submit_turn, key, revision, fn ->
             Remote.submit_frozen_turn(settings, claim, key, revision, artifacts)
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
    Remote.reconcile_after_transport(error, key, settings, fn operation ->
      bind_turn_from_operation(claim, operation, key, settings)
    end)
  end

  defp reconcile_submit_response(claim, key, reason, settings) do
    Remote.reconcile_after_transport(
      Remote.ambiguous_mutation(:submit_turn, reason),
      key,
      settings,
      fn operation -> bind_turn_from_operation(claim, operation, key, settings) end
    )
  end

  defp bind_turn_from_operation(claim, operation, key, settings) do
    case Remote.operation_resource(
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

  @doc false
  def fetch_and_bind_turn(claim, turn_id, settings) do
    with {:ok, remote_turn} <- Remote.fetch_turn(claim, turn_id, settings) do
      bind_turn(claim, remote_turn)
    end
  end

  defp bind_turn(claim, %{"id" => remote_turn_id} = remote_turn)
       when is_binary(remote_turn_id) do
    with :ok <-
           Remote.exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             nil,
             StateBinding.binding_digest(claim.turn)
           ),
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

  @doc false
  def await_turn(claim, %{"state" => "completed"} = remote_turn, settings, _left),
    do: accept_completed(claim, remote_turn, settings)

  def await_turn(claim, remote_turn, settings, left) do
    _activity = Activity.sync(claim.session, settings.api, settings.client)

    with :ok <- Ryker.Accounting.observe_work(claim, remote_turn) do
      continue_await_turn(claim, remote_turn, settings, left)
    end
  end

  defp continue_await_turn(
         claim,
         %{"state" => "awaiting_validation", "candidate" => candidate} = remote_turn,
         settings,
         left
       )
       when is_map(candidate) do
    with {:ok, artifacts} <- output_artifact_metadata(remote_turn) do
      handle_candidate(claim, candidate, artifacts, settings, left)
    end
  end

  defp continue_await_turn(claim, %{"state" => state}, settings, left)
       when state in @turn_waiting_states and left > 0 do
    with :ok <- Remote.pause(settings),
         {:ok, remote_turn} <- Remote.fetch_bound_turn(claim, settings) do
      await_turn(claim, remote_turn, settings, left - 1)
    end
  end

  defp continue_await_turn(_claim, %{"state" => state}, _settings, 0)
       when state in @turn_waiting_states,
       do: {:error, {:work_poll_window_elapsed, :turn}}

  defp continue_await_turn(_claim, %{"state" => state} = turn, _settings, _left)
       when state in @stopped_turn_states do
    {:error, {:work_turn_terminal, state, turn["error_code"], turn["error_detail"]}}
  end

  defp continue_await_turn(_claim, _turn, _settings, _left),
    do: {:error, {:coop_protocol_error, :turn_state}}

  defp handle_candidate(claim, candidate, artifacts, settings, left) do
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
         {:ok, claim} <-
           Validation.ensure_validation_intent(
             claim,
             message,
             sha256,
             attempt,
             artifacts,
             settings
           ),
         {:ok, remote_turn} <- Validation.validate_candidate(claim, settings) do
      await_turn(claim, remote_turn, settings, left)
    end
  end

  defp accept_completed(claim, remote_turn, settings) do
    with {:ok, proof} <- completion_proof(claim, remote_turn) do
      completion_result(finalize_completed(claim, remote_turn, proof, settings), proof)
    end
  end

  @doc false
  def completion_proof(claim, %{"state" => "completed"} = remote_turn) do
    with {:ok, message, sha256, attempt, receipt} <- completed_fields(remote_turn),
         :ok <- completed_matches(claim.turn, message, sha256, attempt) do
      {:ok,
       %{
         "candidate_sha256" => sha256,
         "candidate_attempt" => attempt,
         "remote_turn_id" => claim.turn.coop_turn_id,
         "validation_receipt" => receipt
       }}
    end
  end

  def completion_proof(_claim, _remote_turn),
    do: {:error, {:coop_protocol_error, :completed_turn_state_changed}}

  @doc false
  def completion_result({:error, reason}, proof),
    do: {:error, {:work_completion_blocked, proof, reason}}

  def completion_result(result, _proof), do: result

  @doc false
  def finalize_completed(claim, remote_turn, proof, settings) do
    with {:ok, _turn} <-
           Custody.record_completion(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             proof
           ),
         _activity <- Activity.sync(claim.session, settings.api, settings.client),
         _evidence <- capture_session_evidence(claim, settings),
         :ok <- Ryker.Accounting.observe_work(claim, remote_turn),
         {:ok, remote_session} <- accepted_remote_session(claim, settings),
         {:ok, artifacts} <- output_artifact_metadata(remote_turn),
         {:ok, _stored} <- retain_selected_artifacts(claim, artifacts, settings),
         {:ok, checkpoint} <- checkpoint_accepted_workspace(claim, remote_session, settings),
         :ok <- ensure_checkpoint_publication_offer(claim, checkpoint),
         {:ok, accepted} <-
           Custody.accept_result(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             proof["candidate_sha256"],
             claim.turn.candidate_attempt,
             proof["validation_receipt"],
             Measurement.prepare(remote_turn, remote_session)
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

  # Inspection evidence is observed, never required: its outcome is discarded
  # here so a worker that cannot export it, or a capture that fails, changes
  # nothing about this turn's decisions, prompt bytes, authority or effects.
  defp capture_session_evidence(claim, settings) do
    SessionEvidenceCapture.capture(claim.session, settings.api, settings.client)
  end

  defp checkpoint_accepted_workspace(
         %{session: %{workspace_task: task, repository_ref: repository_ref}} = claim,
         remote_session,
         settings
       )
       when is_map(task) and is_binary(repository_ref) do
    checkpoint_accepted_workspace(
      claim,
      remote_session,
      settings,
      function_exported?(settings.api, :checkpoint_workspace, 4)
    )
  end

  defp checkpoint_accepted_workspace(_claim, _remote_session, _settings), do: {:ok, nil}

  defp checkpoint_accepted_workspace(claim, remote_session, settings, true) do
    with {:ok, expected_revision} <- Remote.revision(remote_session),
         {:ok, %{"transfer_id" => transfer_id}}
         when is_binary(transfer_id) and transfer_id != "" <-
           Remote.api_call(settings, fn ->
             settings.api.checkpoint_workspace(
               settings.client,
               claim.session.coop_session_id,
               Remote.checkpoint_key(claim.turn),
               expected_revision
             )
           end) do
      {:ok, %{"transfer_id" => transfer_id}}
    else
      {:ok, _invalid} -> {:error, {:coop_protocol_error, :workspace_checkpoint}}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_accepted_workspace(_claim, _remote_session, _settings, false),
    do: {:error, {:invalid_work_executor, :workspace_checkpoint_api}}

  defp ensure_checkpoint_publication_offer(_claim, nil), do: :ok

  defp ensure_checkpoint_publication_offer(
         %{session: %{workspace_task: task}, turn: turn},
         %{"transfer_id" => transfer_id}
       )
       when is_map(task) and is_binary(transfer_id) do
    with {:ok, result} <- ValidationIntent.result(turn.validation_intent) do
      maybe_create_publication_offer(task, turn, result)
    end
  end

  defp ensure_checkpoint_publication_offer(_claim, _checkpoint),
    do: {:error, {:coop_protocol_error, :workspace_checkpoint}}

  defp maybe_create_publication_offer(_task, _turn, %{continuation: %{"kind" => "wait"}}), do: :ok

  defp maybe_create_publication_offer(
         task,
         turn,
         %{continuation: %{"kind" => "complete"}} = result
       ) do
    with {:ok, body} <- publication_offer_body(result),
         {:ok, _record} <-
           Records.create(
             Records.token(turn),
             "host:publication:ready",
             "publication_offer",
             %{
               "body" => body,
               "title" => task["title"]
             }
           ) do
      :ok
    end
  end

  defp publication_offer_body(%{delivery_document: %{"message" => message}})
       when is_binary(message) do
    body = message |> String.trim() |> String.byte_slice(0, 8_000)

    if body == "",
      do: {:error, {:coop_protocol_error, :publication_offer}},
      else: {:ok, body}
  end

  defp publication_offer_body(_result),
    do: {:error, {:coop_protocol_error, :publication_offer}}

  defp accepted_remote_session(claim, settings) do
    with {:ok, remote_session} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           Remote.exact_remote_session_state(claim.session, remote_session) do
      {:ok, remote_session}
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

  defp output_artifact_metadata(remote_turn) do
    remote_turn
    |> Map.get("output_artifacts", [])
    |> Outputs.prepare_metadata()
  end

  defp retain_selected_artifacts(claim, metadata, settings) do
    with {:ok, refs} <- accepted_artifact_refs(claim.turn.validation_intent),
         {:ok, selected} <- select_artifact_metadata(metadata, refs),
         selected <- lab_generated_artifacts(claim, metadata, selected),
         {:ok, fetched} <- fetch_output_artifacts(claim, selected, settings) do
      Outputs.put_many(claim.turn.id, fetched)
    end
  end

  # The local console can inspect a completed turn's verified files even when
  # its answer omits them. Slack delivery still receives only selected refs.
  defp lab_generated_artifacts(
         %{episode: %{destination_transport: "control_plane", execution_mode: :live}},
         metadata,
         _selected
       ),
       do: metadata

  defp lab_generated_artifacts(_claim, _metadata, selected), do: selected

  defp accepted_artifact_refs(intent) do
    case ValidationIntent.result(intent) do
      {:ok, %{delivery: :none}} ->
        {:ok, []}

      {:ok, %{delivery_document: %{"outcome" => %{"artifact_refs" => refs}}}}
      when is_list(refs) ->
        {:ok, refs}

      {:ok, %{delivery_document: %{"message" => _message}}} ->
        {:ok, []}

      _invalid ->
        {:error, {:coop_protocol_error, :accepted_artifact_refs}}
    end
  end

  defp select_artifact_metadata(metadata, refs) do
    by_ref = Map.new(metadata, &{&1["id"], &1})

    if Enum.all?(refs, &Map.has_key?(by_ref, &1)),
      do: {:ok, Enum.map(refs, &Map.fetch!(by_ref, &1))},
      else: {:error, {:coop_protocol_error, :accepted_artifact_metadata}}
  end

  defp fetch_output_artifacts(claim, metadata, settings) do
    Enum.reduce_while(metadata, {:ok, []}, fn expected, {:ok, fetched} ->
      result =
        Remote.api_call(settings, fn ->
          settings.api.get_output_artifact(
            settings.client,
            claim.session.coop_session_id,
            claim.turn.coop_turn_id,
            expected["id"]
          )
        end)

      case verify_output_artifact(expected, result) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | fetched]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fetched} -> {:ok, Enum.reverse(fetched)}
      {:error, _reason} = error -> error
    end
  end

  defp verify_output_artifact(expected, {:ok, %{"data" => data} = fetched})
       when is_binary(data) do
    actual = Map.take(fetched, ~w(bytes id media_type sha256))
    expected_identity = Map.take(expected, ~w(bytes id media_type sha256))

    if actual == expected_identity,
      do: {:ok, Map.put(expected, "data", data)},
      else: {:error, {:coop_protocol_error, :output_artifact_identity}}
  end

  defp verify_output_artifact(_expected, {:error, _reason} = error), do: error

  defp verify_output_artifact(_expected, _result),
    do: {:error, {:coop_protocol_error, :output_artifact}}

  @doc false
  def candidate_fields(%{
        "attempt" => attempt,
        "message" => message,
        "sha256" => sha256
      })
      when is_integer(attempt) and attempt > 0 and is_binary(message) and is_binary(sha256) do
    if Remote.digest(message) == sha256,
      do: {:ok, message, sha256, attempt},
      else: {:error, {:coop_protocol_error, :candidate_digest}}
  end

  def candidate_fields(_candidate), do: {:error, {:coop_protocol_error, :candidate}}

  defp completed_fields(%{
         "assistant_message" => message,
         "validation_attempt" => attempt,
         "validation_candidate_sha256" => sha256,
         "validation_receipt" => receipt
       })
       when is_binary(message) and is_integer(attempt) and attempt > 0 and is_binary(sha256) and
              is_binary(receipt) do
    if Remote.digest(message) == sha256 and Remote.reference?(receipt),
      do: {:ok, message, sha256, attempt, receipt},
      else: {:error, {:coop_protocol_error, :validation_receipt}}
  end

  defp completed_fields(%{"validation_attempt" => attempt})
       when not is_integer(attempt) or attempt < 1,
       do: {:error, {:coop_protocol_error, :validation_attempt}}

  defp completed_fields(%{"validation_attempt" => _attempt}),
    do: {:error, {:coop_protocol_error, :validation_receipt}}

  defp completed_fields(_turn), do: {:error, {:coop_protocol_error, :validation_attempt}}
end
