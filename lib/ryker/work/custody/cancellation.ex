defmodule Ryker.Work.Custody.Cancellation do
  @moduledoc """
  Stopping a turn: cancel, transfer, stop, and block requests, their settlement
  against terminal Coop proof, and the recovery of a blocked episode.

  A request freezes its intent on the turn first. When the episode has no turn
  row yet, the request settles in the same transaction; otherwise the turn
  keeps its owner until a leased worker records the exact terminal receipt, and
  only then does the episode cancel or transfer. Blocked work resumes through
  the same transfer path once an operator confirms the exact stopped turn.
  """

  import Ecto.Query
  import Ryker.Work.Custody.Locks

  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet.ControlPlane, as: FleetControlPlane
  alias Ryker.Defaults
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work.Cancellation, as: WorkCancellation
  alias Ryker.Work.Custody.{Sessions, Turns}
  alias Ryker.Work.{Session, Turn, TurnChangeset}

  @doc false
  @spec request_cancel(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_cancel(episode_id, episode_key, turn_ref, cancel_ref, reason) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         {:ok, intent} <- WorkCancellation.new_cancel(cancel_ref, reason) do
      request_cancellation(episode_id, episode_key, turn_ref, intent)
    end
  end

  @doc false
  @spec request_transfer(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_transfer(episode_id, episode_key, turn_ref, new_turn_ref, transfer_ref) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         {:ok, intent} <- WorkCancellation.new_transfer(new_turn_ref, transfer_ref) do
      request_cancellation(episode_id, episode_key, turn_ref, intent)
    end
  end

  @doc false
  @spec request_stop(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_stop(episode_id, episode_key, turn_ref, stop_ref, reason) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(stop_ref, :stop_ref),
         {:ok, intent} <- WorkCancellation.new_block("#{reason} Control: #{stop_ref}.") do
      request_cancellation(episode_id, episode_key, turn_ref, intent)
    end
  end

  @doc false
  @spec request_block(Ecto.UUID.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def request_block(episode_id, episode_key, turn_ref, lease_ref, reason) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, intent} <- WorkCancellation.new_block(reason) do
      request_cancellation(episode_id, episode_key, turn_ref, intent, lease_ref)
    end
  end

  @doc false
  @spec resume_blocked_in_transaction(Episode.t(), String.t() | nil) ::
          {:ok, Episode.t()} | {:error, term()}
  def resume_blocked_in_transaction(%Episode{} = episode, required_input_ref) do
    with :ok <- transaction_open(),
         :ok <- optional_reference(required_input_ref, :required_input_ref),
         {:ok, current} <- Episodes.lock_current_in_transaction(episode.key),
         :ok <- exact_episode(current, episode.id) do
      resume_blocked_owner(current, required_input_ref)
    end
  end

  @doc false
  @spec retry_blocked(String.t(), String.t()) :: {:ok, Episode.t()} | {:error, term()}
  def retry_blocked(episode_key, expected_recovery) do
    with :ok <- reference(episode_key, :episode_key),
         :ok <- reference(expected_recovery, :expected_recovery) do
      Repo.transaction(fn -> retry_blocked_locked(episode_key, expected_recovery) end)
    end
  end

  @doc false
  def recovery_fingerprint(%Turn{} = turn) do
    turn
    |> Map.take([
      :id,
      :status,
      :completion_receipt,
      :candidate_sha256,
      :candidate_attempt,
      :coop_turn_id,
      :result_ref,
      :delivery_ref,
      :cancellation_intent,
      :cancellation_receipt,
      :work_attempt_count,
      :cancel_attempt_count,
      :updated_at
    ])
    |> Jason.encode!()
    |> Jason.decode!()
    |> CanonicalJSON.digest()
  end

  @doc false
  @spec advance_cancellation(Ecto.UUID.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, Turn.t()} | {:error, term()}
  def advance_cancellation(episode_id, turn_ref, lease_ref, expected_generation) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- positive_integer(expected_generation, :cancel_generation) do
      Repo.transaction(fn ->
        advance_cancellation_locked(episode_id, turn_ref, lease_ref, expected_generation)
      end)
    end
  end

  @doc false
  @spec freeze_cancellation_revision(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          :cancel_turn | :close_session,
          pos_integer()
        ) :: {:ok, Turn.t()} | {:error, term()}
  def freeze_cancellation_revision(episode_id, turn_ref, lease_ref, phase, observed_revision) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         :ok <- cancellation_revision_phase(phase),
         :ok <- positive_integer(observed_revision, :cancellation_revision) do
      Repo.transaction(fn ->
        freeze_cancellation_revision_locked(
          episode_id,
          turn_ref,
          lease_ref,
          phase,
          observed_revision
        )
      end)
    end
  end

  defp freeze_cancellation_revision_locked(
         episode_id,
         turn_ref,
         lease_ref,
         phase,
         observed_revision
       ) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)
    field = cancellation_revision_field(phase)

    case Map.fetch!(turn, field) do
      nil ->
        turn
        |> TurnChangeset.freeze_cancellation_revision(phase, observed_revision)
        |> Repo.update()
        |> unwrap_or_rollback(:work_cancellation_revision)

      _frozen_revision ->
        turn
    end
  end

  @doc false
  @spec settle_cancellation(Ecto.UUID.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def settle_cancellation(episode_id, episode_key, turn_ref, lease_ref, receipt) do
    with {:ok, episode_id} <- uuid(episode_id, :episode_id),
         :ok <- reference(episode_key, :episode_key),
         :ok <- reference(turn_ref, :turn_ref),
         :ok <- reference(lease_ref, :lease_ref),
         {:ok, receipt} <- WorkCancellation.prepare_receipt(receipt) do
      fingerprint = WorkCancellation.fingerprint(receipt)

      Repo.transaction(fn ->
        settle_cancellation_locked(
          episode_id,
          episode_key,
          turn_ref,
          lease_ref,
          receipt,
          fingerprint
        )
      end)
    end
  end

  defp request_cancellation(episode_id, episode_key, turn_ref, intent, lease_ref \\ nil) do
    fingerprint = WorkCancellation.fingerprint(intent)

    Repo.transaction(fn ->
      request_cancellation_locked(
        episode_id,
        episode_key,
        turn_ref,
        intent,
        fingerprint,
        lease_ref
      )
    end)
  end

  defp request_cancellation_locked(
         episode_id,
         episode_key,
         turn_ref,
         intent,
         fingerprint,
         lease_ref
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id) do
      request_cancellation_for_identity(
        episode,
        turn_identity(episode_id, turn_ref),
        turn_ref,
        intent,
        fingerprint,
        lease_ref
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_blocked_owner(
         %Episode{state: :working, owner_kind: :turn} = episode,
         required_input_ref
       ) do
    case turn_identity(episode.id, episode.owner_ref) do
      %Turn{
        status: status,
        cancellation_intent: %{"action" => "block"}
      } = identity
      when status in [:cancel_pending, :blocked] ->
        resume_blocked_identity(episode, identity, required_input_ref)

      _other ->
        {:ok, episode}
    end
  end

  defp resume_blocked_owner(%Episode{} = episode, _required_input_ref), do: {:ok, episode}

  defp retry_blocked_locked(episode_key, expected_recovery) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         {:ok, _session, turn} <- lock_turn_after_episode(episode.id, episode.owner_ref) do
      if recovery_fingerprint(turn) != expected_recovery,
        do: Repo.rollback(:work_recovery_changed)

      retry_blocked_episode(episode, turn)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The turn is the episode's owner, already locked in this transaction.
  defp retry_blocked_episode(
         %Episode{state: :working, owner_kind: :turn} = episode,
         %Turn{
           status: :blocked,
           completion_receipt: %{},
           cancellation_intent: nil,
           result_ref: nil,
           delivery_ref: nil
         } = turn
       ) do
    with true <-
           is_nil(turn.operational_pruned_at) and
             Turns.completion_matches?(turn, turn.completion_receipt),
         {:ok, _turn} <- turn |> TurnChangeset.retry_completion() |> Repo.update() do
      episode
    else
      _invalid -> Repo.rollback(:work_completion_not_retryable)
    end
  end

  defp retry_blocked_episode(
         %Episode{state: :working, owner_kind: :turn} = episode,
         %Turn{status: :blocked, cancellation_intent: %{"action" => "block"}} = turn
       ) do
    case resume_blocked_identity(episode, turn, nil) do
      {:ok, resumed} -> resumed
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_blocked_episode(%Episode{}, %Turn{}), do: Repo.rollback(:work_not_blocked)

  defp resume_blocked_identity(episode, identity, required_input_ref) do
    new_turn_ref = "turn:resume-blocked:#{identity.id}:v#{episode.semantic_version}"
    transfer_ref = "transfer:resume-blocked:#{identity.id}:v#{episode.semantic_version}"

    with :ok <- completed_workspace_recoverable(identity),
         {:ok, intent} <-
           WorkCancellation.new_transfer(new_turn_ref, transfer_ref, required_input_ref) do
      fingerprint = WorkCancellation.fingerprint(intent)

      episode
      |> request_cancellation_for_identity(
        identity,
        episode.owner_ref,
        intent,
        fingerprint,
        nil
      )
      |> resumed_episode()
    end
  end

  @doc false
  def completed_workspace_recoverable(
        %Turn{cancellation_receipt: %{"remote_state" => "completed", "session_state" => state}} =
          turn
      )
      when state in ["closed", "discarded"] do
    session = Repo.get!(Session, turn.session_id)

    key =
      "ryker:work:checkpoint:#{turn.id}:a#{turn.candidate_attempt}:#{turn.candidate_sha256}"

    saved =
      Repo.exists?(
        from(t in Ryker.CoopFleet.WorkspaceCheckpointTransfer,
          join: c in Ryker.CoopFleet.Command,
          on: c.id == t.command_id,
          where:
            c.session_id == ^session.id and c.idempotency_key == ^key and c.status == :succeeded
        )
      )

    if is_map(session.workspace_task) and not saved,
      do: {:error, :work_completed_workspace_recovery_required},
      else: :ok
  end

  def completed_workspace_recoverable(_turn), do: :ok

  @doc false
  @spec portable_workspace(Turn.t()) ::
          %{byte_size: pos_integer(), checkpoint_ref: String.t(), repository_ref: String.t()}
          | nil
  def portable_workspace(%Turn{status: :blocked, session_id: session_id})
      when is_binary(session_id) do
    with %Session{} = session <- Repo.get(Session, session_id),
         workspace_ref when is_binary(workspace_ref) <- Settings.work_workspace_ref() do
      FleetControlPlane.portable_workspace(session, %{
        capability_names: Defaults.fetch!(:work).capability_names,
        capability_versions: %{},
        repository_ref: session.repository_ref,
        workspace_ref: workspace_ref
      })
    else
      _unavailable -> nil
    end
  end

  def portable_workspace(_turn), do: nil

  defp resumed_episode(%{episode: episode}), do: {:ok, episode}

  @doc false
  def request_cancellation_for_identity(
        episode,
        nil,
        _turn_ref,
        intent,
        fingerprint,
        _lease_ref
      ),
      do: settle_local_cancellation(episode, nil, intent, fingerprint)

  def request_cancellation_for_identity(
        episode,
        identity,
        turn_ref,
        intent,
        fingerprint,
        lease_ref
      ) do
    with {:ok, session} <- lock_session(episode.id, identity.session_id),
         {:ok, turn} <- lock_turn(episode.id, turn_ref) do
      request_cancellation_for_turn(episode, session, turn, intent, fingerprint, lease_ref)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp request_cancellation_for_turn(episode, session, turn, intent, fingerprint, lease_ref) do
    if exact_cancellation_intent?(turn, fingerprint) do
      retry_cancellation_request(episode, turn, lease_ref)
    else
      prepare_new_cancellation(episode, session, turn, intent, fingerprint, lease_ref)
    end
  end

  defp retry_cancellation_request(episode, turn, lease_ref) do
    case exact_internal_lease(turn, lease_ref) do
      :ok ->
        status =
          if turn.cancellation_receipt != nil or locally_settled_cancellation?(turn),
            do: :settled,
            else: :pending

        %{episode: episode, status: status, turn: turn}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp locally_settled_cancellation?(%Turn{
         status: :blocked,
         coop_turn_id: nil,
         submission: nil,
         remote_operation_kind: nil
       }),
       do: true

  defp locally_settled_cancellation?(%Turn{}), do: false

  defp prepare_new_cancellation(episode, session, turn, intent, fingerprint, lease_ref) do
    with :ok <- valid_cancellation_target(episode, turn, intent),
         :ok <- exact_internal_lease(turn, lease_ref) do
      cond do
        not turn_owner?(episode, turn) ->
          Repo.rollback(:work_episode_owner_lost)

        operator_supersedes_pending_block?(turn, intent) ->
          prepare_cancellation(turn, episode, intent, fingerprint)

        operator_supersedes_settled_block?(turn, intent) ->
          replace_settled_block(episode, session, turn, intent, fingerprint)

        block_follows_operator_intent?(turn, intent) ->
          %{episode: episode, status: :pending, turn: turn}

        conflicting_cancellation?(turn, fingerprint) ->
          Repo.rollback({:work_cancellation_conflict, turn.cancellation_intent_fingerprint})

        true ->
          prepare_cancellation(turn, episode, intent, fingerprint)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_cancellation(turn, episode, intent, fingerprint) do
    turn =
      turn
      |> TurnChangeset.prepare_cancellation(intent, fingerprint, nil)
      |> Repo.update()
      |> unwrap_or_rollback(:work_cancellation_intent)

    %{episode: episode, status: :pending, turn: turn}
  end

  defp exact_cancellation_intent?(turn, fingerprint),
    do: turn.cancellation_intent_fingerprint == fingerprint

  defp valid_cancellation_target(_episode, _turn, %{"action" => action})
       when action in ~w(cancel block),
       do: :ok

  defp valid_cancellation_target(episode, turn, %{
         "action" => "transfer",
         "new_turn_ref" => new_turn_ref
       }) do
    cond do
      new_turn_ref == turn.turn_ref ->
        {:error, :work_transfer_target_conflict}

      Repo.exists?(
        from(existing in Turn,
          where: existing.episode_id == ^episode.id and existing.turn_ref == ^new_turn_ref
        )
      ) ->
        {:error, :work_transfer_target_conflict}

      true ->
        :ok
    end
  end

  defp operator_supersedes_pending_block?(
         %Turn{status: :cancel_pending, cancellation_intent: %{"action" => "block"}},
         %{"action" => action}
       )
       when action in ~w(cancel transfer),
       do: true

  defp operator_supersedes_pending_block?(_turn, _intent), do: false

  defp operator_supersedes_settled_block?(
         %Turn{
           status: :blocked,
           cancellation_intent: %{"action" => "block"},
           cancellation_receipt: receipt
         },
         %{"action" => action}
       )
       when is_map(receipt) and action in ~w(cancel transfer),
       do: true

  defp operator_supersedes_settled_block?(_turn, _intent), do: false

  defp block_follows_operator_intent?(
         %Turn{cancellation_intent: %{"action" => action}},
         %{"action" => "block"}
       )
       when action in ~w(cancel transfer),
       do: true

  defp block_follows_operator_intent?(_turn, _intent), do: false

  defp exact_internal_lease(_turn, nil), do: :ok

  defp exact_internal_lease(turn, lease_ref),
    do: current_turn_lease(turn, lease_ref, Repo.now!())

  defp replace_settled_block(episode, session, turn, intent, fingerprint) do
    now = Repo.now!()

    with :ok <- exact_cancellation_proof(turn.cancellation_receipt, session, turn),
         {:ok, settled_episode} <-
           settle_episode_after_cancellation(
             WorkCancellation.command(intent, episode, now),
             episode,
             turn
           ),
         {:ok, turn} <-
           turn
           |> TurnChangeset.replace_cancellation_disposition(
             intent,
             fingerprint,
             cancellation_error_code(intent),
             cancellation_error_detail(intent),
             :superseded
           )
           |> Repo.update()
           |> persistence_result(:work_cancellation_disposition),
         :ok <- maybe_rotate_cancelled_session(intent, turn.cancellation_receipt, session) do
      %{episode: settled_episode, status: :settled, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp conflicting_cancellation?(turn, fingerprint),
    do: turn.cancellation_intent != nil and turn.cancellation_intent_fingerprint != fingerprint

  defp settle_local_cancellation(episode, nil, intent, _fingerprint) do
    command = WorkCancellation.command(intent, episode, Repo.now!())

    case Episodes.apply_batch_in_transaction([command]) do
      {:ok, [transition]} -> %{episode: transition.episode, status: :settled, turn: nil}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp advance_cancellation_locked(episode_id, turn_ref, lease_ref, expected_generation) do
    {_session, turn} = leased!(episode_id, turn_ref, lease_ref)

    cond do
      turn.status != :cancel_pending ->
        Repo.rollback(:work_cancellation_not_pending)

      turn.cancellation_intent == nil ->
        Repo.rollback(:work_cancellation_intent_not_frozen)

      turn.cancellation_receipt != nil ->
        Repo.rollback(:work_cancellation_already_settled)

      turn.cancel_generation != expected_generation ->
        Repo.rollback({:work_cancel_generation_conflict, turn.cancel_generation})

      true ->
        turn
        |> TurnChangeset.advance_cancel(turn.cancel_generation + 1)
        |> Repo.update()
        |> unwrap_or_rollback(:work_cancel_generation)
    end
  end

  defp settle_cancellation_locked(
         episode_id,
         episode_key,
         turn_ref,
         lease_ref,
         receipt,
         receipt_fingerprint
       ) do
    with {:ok, episode} <- Episodes.lock_current_in_transaction(episode_key),
         :ok <- exact_episode(episode, episode_id),
         {:ok, session, turn} <- lock_turn_after_episode(episode_id, turn_ref) do
      settle_cancellation_turn(
        episode,
        session,
        turn,
        lease_ref,
        receipt,
        receipt_fingerprint
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp settle_cancellation_turn(
         episode,
         session,
         turn,
         lease_ref,
         receipt,
         receipt_fingerprint
       ) do
    now = Repo.now!()

    if cancellation_already_settled?(turn, receipt_fingerprint) do
      %{episode: episode, turn: turn}
    else
      with :ok <- cancellation_pending(turn),
           :ok <- cancellation_intent_frozen(turn),
           :ok <- exact_cancellation_proof(receipt, session, turn),
           :ok <- current_turn_owner(episode, turn),
           :ok <- current_turn_lease(turn, lease_ref, now) do
        persist_cancellation_settlement(
          episode,
          session,
          turn,
          receipt,
          receipt_fingerprint,
          now
        )
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp cancellation_already_settled?(turn, receipt_fingerprint),
    do:
      turn.status in [:blocked, :superseded] and
        turn.cancellation_receipt_fingerprint == receipt_fingerprint

  defp cancellation_pending(%Turn{status: :cancel_pending}), do: :ok
  defp cancellation_pending(_turn), do: {:error, :work_cancellation_not_pending}

  defp cancellation_intent_frozen(%Turn{cancellation_intent: intent})
       when not is_nil(intent),
       do: :ok

  defp cancellation_intent_frozen(_turn),
    do: {:error, :work_cancellation_intent_not_frozen}

  defp exact_cancellation_proof(%{"kind" => "terminal_turn"} = receipt, session, turn) do
    expected_cancel_ref = WorkCancellation.operation_key(turn.id, turn.cancel_generation)

    with :ok <- exact_bound_remote_identity(receipt, session, turn),
         :ok <- optional_exact_reference(receipt["cancel_operation_ref"], expected_cancel_ref),
         do: exact_session_disposition(receipt, session, turn)
  end

  defp exact_cancellation_proof(%{"kind" => "absent_turn"} = receipt, session, turn) do
    expected_submit_ref =
      if turn.submission == nil, do: nil, else: Turns.submit_operation_key(turn)

    with :ok <-
           exact_reference(
             receipt["create_operation_ref"],
             Sessions.create_operation_key(session)
           ),
         :ok <- exact_optional_reference(receipt["submit_operation_ref"], expected_submit_ref),
         :ok <- absent_remote_identity(receipt, session, turn),
         do: exact_session_disposition(receipt, session, turn)
  end

  defp exact_cancellation_proof(_receipt, _session, _turn),
    do: {:error, :work_cancellation_receipt_mismatch}

  defp exact_bound_remote_identity(receipt, session, turn) do
    if is_binary(session.coop_session_id) and is_binary(turn.coop_turn_id) and
         receipt["remote_session_id"] == session.coop_session_id and
         receipt["remote_turn_id"] == turn.coop_turn_id,
       do: :ok,
       else: {:error, :work_cancellation_receipt_mismatch}
  end

  defp absent_remote_identity(receipt, %Session{coop_session_id: nil}, %Turn{coop_turn_id: nil}) do
    if receipt["remote_session_id"] == nil and receipt["session_state"] == nil and
         receipt["close_operation_ref"] == nil,
       do: :ok,
       else: {:error, :work_cancellation_receipt_mismatch}
  end

  defp absent_remote_identity(receipt, session, %Turn{coop_turn_id: nil}) do
    if is_binary(session.coop_session_id) and
         receipt["remote_session_id"] == session.coop_session_id,
       do: :ok,
       else: {:error, :work_cancellation_receipt_mismatch}
  end

  defp absent_remote_identity(_receipt, _session, _turn),
    do: {:error, :work_cancellation_receipt_mismatch}

  defp exact_session_disposition(%{"remote_session_id" => nil}, %Session{}, %Turn{}),
    do: :ok

  defp exact_session_disposition(receipt, session, turn) do
    state = receipt["session_state"]
    close_ref = receipt["close_operation_ref"]

    case {turn.cancellation_intent["action"], state} do
      {"transfer", "open"} ->
        exact_optional_reference(close_ref, nil)

      {_action, state} when state in ~w(closed discarded) ->
        optional_exact_reference(close_ref, cancellation_close_key(turn))

      _other ->
        {:error, :work_cancellation_receipt_mismatch}
    end
    |> case do
      :ok -> exact_reference(receipt["remote_session_id"], session.coop_session_id)
      {:error, _reason} = error -> error
    end
  end

  defp exact_reference(expected, expected), do: :ok
  defp exact_reference(_actual, _expected), do: {:error, :work_cancellation_receipt_mismatch}

  defp exact_optional_reference(nil, nil), do: :ok
  defp exact_optional_reference(actual, expected), do: exact_reference(actual, expected)

  defp optional_exact_reference(nil, _expected), do: :ok
  defp optional_exact_reference(actual, expected), do: exact_reference(actual, expected)

  defp persist_cancellation_settlement(episode, session, turn, receipt, fingerprint, now) do
    command = WorkCancellation.command(turn.cancellation_intent, episode, now)

    with {:ok, settled_episode} <- settle_episode_after_cancellation(command, episode, turn),
         {:ok, turn} <-
           turn
           |> TurnChangeset.settle_cancellation(
             receipt,
             fingerprint,
             now,
             cancellation_error_code(turn.cancellation_intent),
             cancellation_error_detail(turn.cancellation_intent),
             cancellation_status(turn.cancellation_intent)
           )
           |> Repo.update()
           |> persistence_result(:work_cancellation),
         :ok <- maybe_rotate_cancelled_session(turn.cancellation_intent, receipt, session) do
      %{episode: settled_episode, turn: turn}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_rotate_cancelled_session(
         %{"action" => "transfer"},
         %{"session_state" => state},
         session
       )
       when state in ~w(closed discarded) do
    case Sessions.insert_session(
           session.episode_id,
           session.generation + 1,
           Sessions.session_authority(session)
         ) do
      {:ok, _session} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_rotate_cancelled_session(_intent, _receipt, _session), do: :ok

  defp settle_episode_after_cancellation(nil, episode, _turn), do: {:ok, episode}

  defp settle_episode_after_cancellation(command, _episode, turn) do
    case Episodes.apply_batch_in_transaction([command], settled_work_turn_id: turn.id) do
      {:ok, [transition]} -> {:ok, transition.episode}
      {:error, _reason} = error -> error
    end
  end

  defp cancellation_error_code(%{"action" => "cancel"}), do: "operator_cancelled"
  defp cancellation_error_code(%{"action" => "transfer"}), do: "owner_transferred"
  defp cancellation_error_code(%{"action" => "block"}), do: "work_execution_blocked"

  defp cancellation_error_detail(%{"action" => "block", "reason" => reason}), do: reason

  defp cancellation_error_detail(_intent),
    do: "The bound Coop turn stopped before episode ownership changed."

  defp cancellation_status(%{"action" => "block"}), do: :blocked
  defp cancellation_status(_intent), do: :superseded

  defp cancellation_revision_phase(phase) when phase in [:cancel_turn, :close_session], do: :ok

  defp cancellation_revision_phase(_phase),
    do: {:error, {:invalid_work_custody, :cancellation_revision_phase}}

  defp cancellation_revision_field(:cancel_turn), do: :cancel_expected_revision
  defp cancellation_revision_field(:close_session), do: :close_expected_revision

  defp cancellation_close_key(turn),
    do: "ryker:work:cancel-close:#{turn.id}:g#{turn.cancel_generation}"
end
