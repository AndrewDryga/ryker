defmodule Ryker.Work.Custody.Turns do
  @moduledoc """
  One logical turn from frozen submission to accepted result.

  Each step freezes its exact input before the matching Coop mutation runs:
  the submission, the final preflight, the staged candidate, the validation
  verdict, and finally the accepted result that advances the episode. The
  mutation fence commits the durable request identity of an outbound Coop
  create or submit before the call and renews the lease under lock for every
  fenced kind, so a lost response is replayed against the same key instead of
  blindly repeated.
  """

  import Ryker.Work.Custody.Locks

  alias Ryker.Artifacts.References, as: ArtifactReferences
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode, RoutingDigests}
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Repo
  alias Ryker.State.{Continuity, EventSubscriptions, KnowledgeSnapshot}
  alias Ryker.Work.Custody.{Claims, Delivery}

  alias Ryker.Work.{
    CandidateResponse,
    FinalPreflight,
    Measurement,
    Result,
    Submission,
    Turn,
    TurnChangeset,
    ValidationIntent
  }

  @spec freeze_submission(Ecto.UUID.t(), String.t(), String.t(), Submission.t(), keyword()) ::
          {:ok, Turn.t()} | {:error, term()}
  def freeze_submission(episode_id, turn_ref, lease_ref, submission, options \\ []) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, submission} <- Submission.prepare(submission) do
      fingerprint = Submission.fingerprint(submission)
      evidence = Keyword.take(options, [:selected_input_refs, :selection_ledger])

      Repo.transaction(fn ->
        freeze_locked(episode_id, turn_ref, lease_ref, submission, fingerprint, evidence)
      end)
    end
  end

  @doc false
  @spec record_final_preflight(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def record_final_preflight(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        ledger_sha256,
        semantic_version
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :final_preflight_candidate_sha256),
         :ok <- sha256(ledger_sha256, :final_preflight_ledger_sha256),
         :ok <- non_negative_integer(semantic_version, :final_preflight_semantic_version) do
      Repo.transaction(fn ->
        {_, turn} = leased!(episode_id, turn_ref, lease_ref)
        continuity_sha256 = Continuity.preflight_fingerprint_in_transaction(turn)

        turn
        |> TurnChangeset.record_final_preflight(
          candidate_sha256,
          continuity_sha256,
          ledger_sha256,
          semantic_version
        )
        |> Repo.update()
        |> unwrap_or_rollback(:work_final_preflight)
      end)
    end
  end

  @doc false
  @spec verify_final_preflight(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          [String.t()]
        ) :: {:ok, Turn.t()} | {:error, term()}
  def verify_final_preflight(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        artifact_refs
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :final_preflight_candidate_sha256),
         :ok <- artifact_refs(artifact_refs) do
      Repo.transaction(fn ->
        verify_final_preflight_locked(
          episode_id,
          turn_ref,
          lease_ref,
          candidate_sha256,
          artifact_refs
        )
      end)
    end
  end

  defp verify_final_preflight_locked(
         episode_id,
         turn_ref,
         lease_ref,
         candidate_sha256,
         artifact_refs
       ) do
    {_, turn} = leased!(episode_id, turn_ref, lease_ref)
    episode = Repo.get!(Episode, episode_id)

    ledger_sha256 =
      FinalPreflight.ledger_sha256(
        episode.id,
        episode.semantic_version,
        artifact_refs,
        turn.id
      )

    continuity_sha256 = Continuity.preflight_fingerprint_in_transaction(turn)

    if turn.final_preflight_candidate_sha256 == candidate_sha256 and
         turn.final_preflight_continuity_sha256 == continuity_sha256 and
         turn.final_preflight_ledger_sha256 == ledger_sha256 and
         turn.final_preflight_semantic_version == episode.semantic_version do
      turn
    else
      Repo.rollback(:work_final_preflight_required)
    end
  end

  @doc false
  @spec bind_state_tools(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def bind_state_tools(episode_id, turn_ref, lease_ref, endpoint, token_sha256) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(endpoint, 2_048, :state_tools_endpoint),
         :ok <- sha256(token_sha256, :state_tools_token_sha256) do
      Repo.transaction(fn ->
        bind_state_tools_locked(episode_id, turn_ref, lease_ref, endpoint, token_sha256)
      end)
    end
  end

  @doc false
  @spec bind_turn(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def bind_turn(
        episode_id,
        turn_ref,
        lease_ref,
        session_generation,
        submit_generation,
        coop_turn_id
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(session_generation, :session_generation),
         :ok <- positive_integer(submit_generation, :submit_generation),
         :ok <- reference(coop_turn_id, :coop_turn_id) do
      Repo.transaction(fn ->
        bind_turn_locked(
          episode_id,
          turn_ref,
          lease_ref,
          session_generation,
          submit_generation,
          coop_turn_id
        )
      end)
    end
  end

  @doc false
  @spec advance_turn_submit(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  def advance_turn_submit(episode_id, turn_ref, lease_ref, expected_generation) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :submit_generation) do
      Repo.transaction(fn ->
        advance_turn_submit_locked(episode_id, turn_ref, lease_ref, expected_generation)
      end)
    end
  end

  @doc false
  @spec stage_candidate(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          pos_integer() | nil,
          String.t(),
          String.t(),
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def stage_candidate(
        episode_id,
        turn_ref,
        lease_ref,
        expected_candidate_sha256,
        expected_candidate_attempt,
        candidate,
        candidate_sha256,
        candidate_attempt
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <-
           optional_candidate_identity(
             expected_candidate_sha256,
             expected_candidate_attempt
           ),
         :ok <- candidate(candidate),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         :ok <- exact_sha256(candidate, candidate_sha256) do
      Repo.transaction(fn ->
        stage_candidate_locked(
          episode_id,
          turn_ref,
          lease_ref,
          expected_candidate_sha256,
          expected_candidate_attempt,
          candidate,
          candidate_sha256,
          candidate_attempt
        )
      end)
    end
  end

  @doc false
  @spec prepare_validation(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          :accept | {:reject, [String.t()]},
          Result.t() | nil
        ) :: {:ok, Turn.t()} | {:error, term()}
  def prepare_validation(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        candidate_attempt,
        verdict,
        result
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         {:ok, intent} <- ValidationIntent.new(verdict, result) do
      fingerprint = ValidationIntent.fingerprint(intent)

      Repo.transaction(fn ->
        prepare_validation_locked(
          episode_id,
          turn_ref,
          lease_ref,
          candidate_sha256,
          candidate_attempt,
          intent,
          fingerprint
        )
      end)
    end
  end

  @doc false
  @spec advance_validation(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def advance_validation(
        episode_id,
        turn_ref,
        lease_ref,
        candidate_sha256,
        candidate_attempt,
        expected_generation
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         :ok <- positive_integer(expected_generation, :validation_generation) do
      Repo.transaction(fn ->
        advance_validation_locked(
          episode_id,
          turn_ref,
          lease_ref,
          candidate_sha256,
          candidate_attempt,
          expected_generation
        )
      end)
    end
  end

  @doc false
  @spec accept_result(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          pos_integer(),
          String.t(),
          map()
        ) :: {:ok, %{episode: Episode.t(), turn: Turn.t()}} | {:error, term()}
  def accept_result(
        episode_id,
        episode_key,
        turn_ref,
        lease_ref,
        candidate_sha256,
        candidate_attempt,
        validation_receipt,
        measurement \\ %{}
      ) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- sha256(candidate_sha256, :candidate_sha256),
         :ok <- positive_integer(candidate_attempt, :candidate_attempt),
         :ok <- reference(validation_receipt, :validation_receipt),
         :ok <- measurement(measurement) do
      Repo.transaction(fn ->
        accept_result_locked(
          episode_id,
          episode_key,
          turn_ref,
          lease_ref,
          candidate_sha256,
          candidate_attempt,
          validation_receipt,
          measurement
        )
      end)
    end
  end

  @doc false
  def record_completion(episode_id, turn_ref, lease_ref, receipt) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref) do
      Repo.transaction(fn ->
        record_completion_locked(episode_id, turn_ref, lease_ref, receipt)
      end)
    end
  end

  defp record_completion_locked(episode_id, turn_ref, lease_ref, receipt) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if completion_matches?(turn, receipt) and turn.status == :pending and
         is_nil(turn.cancellation_intent) and is_nil(turn.result_ref) do
      turn
      |> TurnChangeset.record_completion(receipt)
      |> Repo.update()
      |> unwrap_or_rollback(:work_completion_record)
    else
      Repo.rollback(:work_completion_receipt_mismatch)
    end
  end

  @doc false
  def block_completion(episode_id, turn_ref, lease_ref, receipt, code, detail) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- bounded_text(code, 128, :error_code),
         :ok <- bounded_text(detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        block_completion_locked(episode_id, turn_ref, lease_ref, receipt, code, detail)
      end)
    end
  end

  defp block_completion_locked(episode_id, turn_ref, lease_ref, receipt, code, detail) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if completion_matches?(turn, receipt) and turn.status == :pending and
         is_nil(turn.cancellation_intent) and is_nil(turn.result_ref) do
      turn
      |> TurnChangeset.block_completion(receipt, code, detail)
      |> Repo.update()
      |> unwrap_or_rollback(:work_completion_block)
    else
      Repo.rollback(:work_completion_receipt_mismatch)
    end
  end

  @doc false
  def completion_matches?(
        turn,
        %{
          "candidate_sha256" => sha,
          "candidate_attempt" => attempt,
          "remote_turn_id" => remote_id,
          "validation_receipt" => receipt
        } = proof
      ) do
    map_size(proof) == 4 and turn.candidate_sha256 == sha and turn.candidate_attempt == attempt and
      turn.coop_turn_id == remote_id and is_binary(remote_id) and
      (is_nil(turn.completion_receipt) or turn.completion_receipt == proof) and
      get_in(turn.validation_intent, ["verdict"]) == "accept" and
      reference(receipt, :validation_receipt) == :ok
  end

  def completion_matches?(_turn, _receipt), do: false

  @doc false
  @spec with_mutation_fence(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          map(),
          (-> result)
        ) :: result | {:error, term()}
        when result: term()
  def with_mutation_fence(
        episode_id,
        turn_ref,
        lease_ref,
        request,
        callback
      ) do
    with {:ok, request} <- mutation_fence_request(request),
         {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- remote_operation_kind(request.kind),
         :ok <- remote_operation_revision(request.kind, request.operation_revision),
         :ok <- reference(request.operation_key, :operation_key),
         :ok <- positive_integer(request.lease_seconds, :lease_seconds),
         :ok <- callback(callback),
         :ok <-
           prepare_remote_operation(
             episode_id,
             turn_ref,
             lease_ref,
             request.kind,
             request.operation_key,
             request.operation_revision
           ),
         :ok <- authorize_remote_mutation(episode_id, turn_ref, lease_ref, request) do
      callback.()
    end
  end

  defp mutation_fence_request(
         %{
           kind: kind,
           lease_seconds: lease_seconds,
           operation_key: operation_key,
           operation_revision: operation_revision
         } = request
       )
       when map_size(request) == 4 do
    {:ok,
     %{
       kind: kind,
       lease_seconds: lease_seconds,
       operation_key: operation_key,
       operation_revision: operation_revision
     }}
  end

  defp mutation_fence_request(_request),
    do: {:error, {:invalid_work_mutation_fence, :request}}

  defp authorize_remote_mutation(episode_id, turn_ref, lease_ref, request) do
    Repo.transaction(fn ->
      remote_mutation_turn!(
        episode_id,
        turn_ref,
        lease_ref,
        request.kind,
        request.operation_key,
        request.lease_seconds,
        request.operation_revision
      )
    end)
    |> mutation_authorization_result()
  end

  defp mutation_authorization_result({:ok, _turn}), do: :ok
  defp mutation_authorization_result({:error, _reason} = error), do: error

  defp prepare_remote_operation(
         _episode_id,
         _turn_ref,
         _lease_ref,
         kind,
         _operation_key,
         _operation_revision
       )
       when kind not in [:create_session, :submit_turn],
       do: :ok

  defp prepare_remote_operation(
         episode_id,
         turn_ref,
         lease_ref,
         kind,
         operation_key,
         operation_revision
       ) do
    case Repo.transaction(fn ->
           prepare_remote_operation_locked(
             episode_id,
             turn_ref,
             lease_ref,
             kind,
             operation_key,
             operation_revision
           )
         end) do
      {:ok, _turn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_remote_operation_locked(
         episode_id,
         turn_ref,
         lease_ref,
         kind,
         operation_key,
         operation_revision
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    kind = Atom.to_string(kind)

    cond do
      turn.remote_operation_kind == nil ->
        persist_remote_operation(turn, kind, operation_key, operation_revision)

      turn.remote_operation_kind == kind and turn.remote_operation_key == operation_key and
          turn.remote_operation_revision == operation_revision ->
        persist_remote_operation(turn, kind, operation_key, operation_revision)

      true ->
        Repo.rollback(
          {:work_remote_operation_conflict,
           {turn.remote_operation_kind, turn.remote_operation_key}}
        )
    end
  end

  defp persist_remote_operation(turn, kind, operation_key, operation_revision) do
    turn
    |> TurnChangeset.prepare_remote_operation(kind, operation_key, operation_revision)
    |> Repo.update()
    |> unwrap_or_rollback(:work_remote_operation)
  end

  defp remote_mutation_turn!(
         episode_id,
         turn_ref,
         lease_ref,
         kind,
         operation_key,
         lease_seconds,
         operation_revision
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    if kind in [:create_session, :submit_turn] do
      if frozen_remote_operation?(turn, kind, operation_key, operation_revision),
        do: Claims.renew_locked(episode_id, turn_ref, lease_ref, lease_seconds),
        else: Repo.rollback(:work_remote_operation_not_frozen)
    else
      Claims.renew_locked(episode_id, turn_ref, lease_ref, lease_seconds)
    end
  end

  defp frozen_remote_operation?(turn, kind, operation_key, operation_revision) do
    turn.remote_operation_kind == Atom.to_string(kind) and
      turn.remote_operation_key == operation_key and
      turn.remote_operation_revision == operation_revision
  end

  defp freeze_locked(episode_id, turn_ref, lease_ref, submission, fingerprint, evidence) do
    case turn_for_lease(episode_id, turn_ref, lease_ref) do
      {:ok, _session, %Turn{submission: nil} = turn} ->
        frozen =
          turn
          |> TurnChangeset.freeze(submission, fingerprint, evidence)
          |> Repo.update()
          |> unwrap_or_rollback(:work_submission)

        attach_submission_artifacts(frozen, submission)

      {:ok, _session, %Turn{submission_fingerprint: ^fingerprint} = turn} ->
        attach_submission_artifacts(turn, submission)

      {:ok, _session, %Turn{submission_fingerprint: stored}} ->
        Repo.rollback({:work_submission_conflict, stored})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp attach_submission_artifacts(turn, submission) do
    case ArtifactReferences.attach_turn(turn.id, submission["input_artifact_refs"]) do
      :ok -> turn
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp bind_state_tools_locked(episode_id, turn_ref, lease_ref, endpoint, token_sha256) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.state_tools_endpoint == endpoint and
          turn.state_tools_token_sha256 == token_sha256 ->
        turn

      is_nil(turn.state_tools_endpoint) and is_nil(turn.state_tools_token_sha256) ->
        turn
        |> TurnChangeset.bind_state_tools(endpoint, token_sha256)
        |> Repo.update()
        |> unwrap_or_rollback(:work_state_tools_binding)

      true ->
        Repo.rollback(:work_state_tools_binding_conflict)
    end
  end

  defp bind_turn_locked(
         episode_id,
         turn_ref,
         lease_ref,
         session_generation,
         submit_generation,
         coop_turn_id
       ) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      session.generation != session_generation ->
        Repo.rollback({:work_session_generation_conflict, session.generation})

      session.coop_session_id == nil ->
        Repo.rollback(:work_session_not_bound)

      turn.submit_generation != submit_generation ->
        Repo.rollback({:work_turn_submit_generation_conflict, turn.submit_generation})

      turn.submission == nil ->
        Repo.rollback(:work_submission_not_frozen)

      turn.coop_turn_id == nil ->
        turn = clear_remote_operation!(turn, "submit_turn", submit_operation_key(turn))

        turn
        |> TurnChangeset.bind_coop_turn(coop_turn_id)
        |> Repo.update()
        |> unwrap_or_rollback(:work_turn_binding)

      turn.coop_turn_id == coop_turn_id ->
        clear_remote_operation!(turn, "submit_turn", submit_operation_key(turn))

      true ->
        Repo.rollback({:work_turn_conflict, turn.coop_turn_id})
    end
  end

  defp advance_turn_submit_locked(episode_id, turn_ref, lease_ref, expected_generation) do
    {session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      session.coop_session_id == nil ->
        Repo.rollback(:work_session_not_bound)

      turn.submission == nil ->
        Repo.rollback(:work_submission_not_frozen)

      turn.coop_turn_id != nil ->
        Repo.rollback(:work_turn_already_bound)

      turn.submit_generation != expected_generation ->
        Repo.rollback({:work_turn_submit_generation_conflict, turn.submit_generation})

      true ->
        turn = clear_remote_operation!(turn, "submit_turn", submit_operation_key(turn))

        turn
        |> TurnChangeset.advance_submit(turn.submit_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_turn_submit_generation)
    end
  end

  defp stage_candidate_locked(
         episode_id,
         turn_ref,
         lease_ref,
         expected_candidate_sha256,
         expected_candidate_attempt,
         candidate,
         candidate_sha256,
         candidate_attempt
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    case candidate_action(
           turn,
           expected_candidate_sha256,
           expected_candidate_attempt,
           candidate,
           candidate_sha256,
           candidate_attempt
         ) do
      %Turn{} = staged ->
        record_candidate_response!(staged)

        case Continuity.candidate_staged_in_transaction(
               staged,
               candidate_sha256,
               candidate_attempt
             ) do
          :ok -> staged
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp record_candidate_response!(%Turn{operational_pruned_at: pruned}) when not is_nil(pruned),
    do: Repo.rollback(:work_candidate_response_pruned)

  defp record_candidate_response!(turn) do
    # The lease check holds the owning turn lock, also used by operational
    # pruning. Record only these supplied bytes, never backfill an older cursor.
    identity = [turn_id: turn.id, candidate_attempt: turn.candidate_attempt]
    bytes = byte_size(turn.candidate)

    case Repo.get_by(CandidateResponse, identity) do
      nil ->
        Repo.insert!(%CandidateResponse{
          turn_id: turn.id,
          candidate_attempt: turn.candidate_attempt,
          body: turn.candidate,
          sha256: turn.candidate_sha256,
          byte_size: bytes,
          recorded_at: Repo.now!()
        })

      %CandidateResponse{operational_pruned_at: pruned} when not is_nil(pruned) ->
        Repo.rollback(:work_candidate_response_pruned)

      %CandidateResponse{body: body, sha256: sha256, byte_size: ^bytes}
      when body == turn.candidate and sha256 == turn.candidate_sha256 ->
        :ok

      %CandidateResponse{} ->
        Repo.rollback({:work_candidate_response_conflict, turn.candidate_attempt})
    end
  end

  defp candidate_action(
         %Turn{coop_turn_id: nil},
         _expected_sha,
         _expected_attempt,
         _body,
         _sha,
         _attempt
       ),
       do: Repo.rollback(:work_turn_not_bound)

  defp candidate_action(
         %Turn{result_ref: result_ref},
         _expected_sha,
         _expected_attempt,
         _body,
         _sha,
         _attempt
       )
       when not is_nil(result_ref),
       do: Repo.rollback(:work_result_already_accepted)

  defp candidate_action(turn, _expected_sha, _expected_attempt, body, sha, attempt)
       when turn.candidate == body and turn.candidate_sha256 == sha and
              turn.candidate_attempt == attempt,
       do: turn

  defp candidate_action(
         %Turn{candidate_sha256: nil} = turn,
         nil,
         _expected_attempt,
         body,
         sha,
         attempt
       ) do
    turn
    |> TurnChangeset.stage_candidate(body, sha, attempt)
    |> Repo.update()
    |> unwrap_or_rollback(:work_candidate)
  end

  defp candidate_action(turn, expected_sha, expected_attempt, body, sha, attempt)
       when turn.candidate_sha256 == expected_sha and turn.candidate_attempt == expected_attempt and
              attempt > expected_attempt do
    turn
    |> TurnChangeset.replace_candidate(body, sha, attempt)
    |> Repo.update()
    |> unwrap_or_rollback(:work_candidate)
  end

  defp candidate_action(turn, expected_sha, expected_attempt, _body, _sha, _attempt)
       when turn.candidate_sha256 == expected_sha and turn.candidate_attempt == expected_attempt,
       do: Repo.rollback({:work_candidate_attempt_conflict, turn.candidate_attempt})

  defp candidate_action(turn, _expected_sha, _expected_attempt, _body, _sha, _attempt),
    do: Repo.rollback({:work_candidate_conflict, turn.candidate_sha256})

  defp advance_validation_locked(
         episode_id,
         turn_ref,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         expected_generation
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.result_ref != nil ->
        Repo.rollback(:work_result_already_accepted)

      turn.candidate_sha256 != candidate_sha256 or
          turn.candidate_attempt != candidate_attempt ->
        Repo.rollback({:work_candidate_conflict, turn.candidate_sha256})

      turn.validation_generation != expected_generation ->
        Repo.rollback({:work_validation_generation_conflict, turn.validation_generation})

      turn.validation_intent == nil ->
        Repo.rollback(:work_validation_intent_not_frozen)

      true ->
        turn
        |> TurnChangeset.advance_validation(turn.validation_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_validation_generation)
    end
  end

  defp prepare_validation_locked(
         episode_id,
         turn_ref,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         intent,
         fingerprint
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.result_ref != nil ->
        Repo.rollback(:work_result_already_accepted)

      turn.coop_turn_id == nil ->
        Repo.rollback(:work_turn_not_bound)

      turn.candidate_sha256 != candidate_sha256 or
          turn.candidate_attempt != candidate_attempt ->
        Repo.rollback({:work_candidate_conflict, turn.candidate_sha256})

      turn.validation_intent_fingerprint == fingerprint ->
        turn

      turn.validation_intent != nil ->
        Repo.rollback({:work_validation_intent_conflict, turn.validation_intent_fingerprint})

      true ->
        persist_validation_intent(turn, intent, fingerprint)
    end
  end

  defp persist_validation_intent(turn, intent, fingerprint) do
    case validation_intent_ready(intent) do
      :ok ->
        turn
        |> TurnChangeset.prepare_validation(intent, fingerprint, Repo.now!())
        |> Repo.update()
        |> unwrap_or_rollback(:work_validation_intent)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp accept_result_locked(
         episode_id,
         episode_key,
         turn_ref,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         measurement
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id),
         {:ok, session, turn} <- lock_turn_after_episode(episode_id, turn_ref),
         {:ok, result} <- accepted_intent_result(turn),
         {:continue, command, attributes} <-
           prepare_result_acceptance(
             episode,
             turn,
             lease_ref,
             candidate_sha256,
             candidate_attempt,
             validation_receipt,
             result,
             measurement
           ),
         :ok <- KnowledgeSnapshot.authorize_session(episode, session),
         :ok <-
           KnowledgeSnapshot.authorize_submission(
             episode,
             session.repository_ref,
             turn.submission
           ),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, turn} <-
           turn
           |> TurnChangeset.accept_result(attributes)
           |> Repo.update()
           |> persistence_result(:work_result),
         :ok <-
           PublicationCustody.ensure_task_review_in_transaction(
             transition.episode,
             session,
             turn
           ),
         :ok <- Ryker.Accounting.accepted_in_transaction(episode, session, turn),
         {:ok, _subscription} <- EventSubscriptions.ensure_in_transaction(transition.episode),
         :ok <- Continuity.accept_staged_in_transaction(episode, session, turn, turn.result_ref),
         :ok <- RoutingDigests.accept_title_in_transaction(episode, turn) do
      %{episode: transition.episode, turn: turn}
    else
      {:accepted, turn} -> %{episode: episode_for_result!(episode_key), turn: turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_result_acceptance(
         episode,
         turn,
         lease_ref,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         result,
         measurement
       ) do
    now = Repo.now!()
    result_ref = "result:#{turn.id}"
    delivery_ref = if result.delivery == :reply, do: "delivery:#{turn.id}"
    delivery_target = if result.delivery == :reply, do: Delivery.reply_target(episode, turn)

    delivery_fingerprint =
      if result.delivery_document,
        do: CanonicalJSON.digest(result.delivery_document)

    attributes =
      measurement
      |> Measurement.acceptance_attributes(now)
      |> Map.merge(%{
        accepted_at: now,
        continuation: result.continuation,
        delivery_document: result.delivery_document,
        delivery_fingerprint: delivery_fingerprint,
        delivery_ref: delivery_ref,
        delivery_target: delivery_target,
        result_ref: result_ref,
        status: acceptance_status(result.delivery),
        validation_receipt: validation_receipt
      })

    if result_already_accepted?(
         turn,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         attributes
       ) do
      {:accepted, turn}
    else
      with :ok <- result_not_accepted(turn),
           :ok <- current_turn_owner(episode, turn),
           :ok <- current_turn_lease(turn, lease_ref, now),
           :ok <- pending_turn(turn),
           :ok <- bound_turn(turn),
           :ok <- exact_candidate(turn, candidate_sha256, candidate_attempt) do
        build_result_acceptance(episode, turn, result, attributes, result_ref, delivery_ref, now)
      end
    end
  end

  defp result_not_accepted(%Turn{result_ref: nil}), do: :ok

  defp result_not_accepted(%Turn{result_ref: result_ref}),
    do: {:error, {:work_result_conflict, result_ref}}

  defp pending_turn(%Turn{status: :pending}), do: :ok
  defp pending_turn(_turn), do: {:error, :work_turn_not_pending}

  defp bound_turn(%Turn{coop_turn_id: turn_id}) when is_binary(turn_id), do: :ok
  defp bound_turn(_turn), do: {:error, :work_turn_not_bound}

  defp exact_candidate(turn, sha256, attempt) do
    if turn.candidate_sha256 == sha256 and turn.candidate_attempt == attempt,
      do: :ok,
      else: {:error, {:work_candidate_conflict, turn.candidate_sha256}}
  end

  defp build_result_acceptance(episode, turn, result, attributes, result_ref, delivery_ref, now) do
    {next_turn, next_wait} =
      if result.delivery == :none,
        do:
          Delivery.delivery_continuation(
            episode,
            %{turn | continuation: result.continuation},
            now
          ),
        else: {next_turn_ref(episode, result.delivery, turn.id), nil}

    command = %Command.AcceptResult{
      decision_reason: result.decision_reason,
      delivery: result.delivery,
      delivery_ref: delivery_ref,
      episode_key: episode.key,
      expected_turn_ref: turn.turn_ref,
      next_turn_ref: next_turn,
      next_wait: next_wait,
      occurred_at: now,
      result_ref: result_ref
    }

    {:continue, command, release_lease(attributes)}
  end

  defp result_already_accepted?(
         turn,
         candidate_sha256,
         candidate_attempt,
         validation_receipt,
         attributes
       ) do
    turn.result_ref == attributes.result_ref and
      turn.candidate_sha256 == candidate_sha256 and
      turn.candidate_attempt == candidate_attempt and
      turn.validation_receipt == validation_receipt and
      turn.delivery_ref == attributes.delivery_ref and
      turn.delivery_fingerprint == attributes.delivery_fingerprint and
      turn.delivery_document == attributes.delivery_document and
      turn.continuation == attributes.continuation and
      turn.status in [:delivery_pending, :settled, :superseded]
  end

  defp acceptance_status(:reply), do: :delivery_pending
  defp acceptance_status(:none), do: :settled

  defp release_lease(attributes) do
    Map.merge(attributes, %{
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil
    })
  end

  defp next_turn_ref(%Episode{queued_input_refs: []}, _phase, _turn_id), do: nil
  defp next_turn_ref(_episode, :reply, _turn_id), do: nil
  defp next_turn_ref(_episode, _phase, turn_id), do: "turn:after:#{turn_id}"

  defp validation_intent_ready(intent) do
    case ValidationIntent.result(intent) do
      {:ok, nil} -> :ok
      {:ok, result} -> Result.validate_at(result, Repo.now!())
      {:error, _reason} -> {:error, :work_validation_intent_invalid}
    end
  end

  defp accepted_intent_result(%Turn{validation_intent: intent}) when is_map(intent) do
    case ValidationIntent.result(intent) do
      {:ok, %Result{} = result} -> {:ok, result}
      {:ok, nil} -> {:error, :work_validation_intent_not_accept}
      {:error, _reason} -> {:error, :work_validation_intent_invalid}
    end
  end

  defp accepted_intent_result(%Turn{}), do: {:error, :work_validation_intent_not_frozen}

  defp remote_operation_kind(kind)
       when kind in [
              :create_session,
              :submit_turn,
              :validate_candidate,
              :cancel_turn,
              :close_session
            ],
       do: :ok

  defp remote_operation_kind(_kind),
    do: {:error, {:invalid_work_custody, :remote_operation_kind}}

  defp remote_operation_revision(:submit_turn, revision),
    do: positive_integer(revision, :remote_operation_revision)

  defp remote_operation_revision(_kind, nil), do: :ok

  defp remote_operation_revision(_kind, _revision),
    do: {:error, {:invalid_work_custody, :remote_operation_revision}}

  @doc false
  def clear_remote_operation!(%Turn{remote_operation_kind: nil} = turn, _kind, _key), do: turn

  def clear_remote_operation!(
        %Turn{remote_operation_kind: kind, remote_operation_key: key} = turn,
        kind,
        key
      ) do
    turn
    |> TurnChangeset.clear_remote_operation()
    |> Repo.update()
    |> unwrap_or_rollback(:work_remote_operation)
  end

  def clear_remote_operation!(turn, _kind, _key) do
    Repo.rollback(
      {:work_remote_operation_conflict, {turn.remote_operation_kind, turn.remote_operation_key}}
    )
  end

  @doc false
  def submit_operation_key(turn),
    do: "ryker:work:turn:#{turn.id}:g#{turn.submit_generation}:#{turn.submission_fingerprint}"
end
