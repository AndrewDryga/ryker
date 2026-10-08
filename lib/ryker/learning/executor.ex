defmodule Ryker.Learning.Executor do
  @moduledoc "One resumable, bounded learning step. All remote effects use the frozen run identity."
  alias Ryker.Coop
  alias Ryker.CoopFleet
  alias Ryker.{Learning, Repo}
  alias Ryker.Learning.{Batches, FleetSession, LearningRun}
  alias Ryker.Work

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @pending ~w(reserved running)

  def step(claim, run, settings) do
    result =
      case Learning.authorize(run.id, claim) do
        {:ok, run} ->
          if Repo.passed?(run.started_at, settings.execution_timeout_seconds),
            do: stop(claim, run, :learning_execution_timeout, settings),
            else: execute(claim, run, settings)

        {:error, :learning_lease_lost} ->
          {:error, :learning_lease_lost}

        {:error, reason} ->
          stop(claim, run, reason, settings)
      end

    case result do
      {:error, {:operation_failed, phase, operation}} ->
        with {:ok, _} <- Learning.end_attempt(run.id, :learning_provider_failed, claim),
             {:ok, _} <-
               Learning.record_fenced_absence(
                 run.id,
                 phase,
                 Learning.operation_key(run, phase),
                 operation,
                 claim
               ),
             do: {:error, :learning_provider_failed}

      other ->
        other
    end
  end

  defp execute(claim, run, settings) do
    case remote_session(claim, run, settings, :create) do
      {:ok, %{} = session} ->
        with :ok <- disclosable(claim, run, session, settings),
             {:ok, %{} = turn} <- remote_turn(claim, run, session, settings, :submit),
             do: process_turn(claim, run, session, turn, settings)

      {:error, reason} ->
        if unaddressable?(run, reason),
          do: stop(claim, run, :learning_session_unconfirmed, settings),
          else: {:error, reason}

      other ->
        other
    end
  end

  # Binding needs only the session's exact identity, so a session this run owns
  # is bound even when its authority is unusable and cleanup can close it.
  defp remote_session(claim, run, settings, mode) do
    local = Repo.fetch!(Work.Session.Query.by_learning_run_id(run.id))

    if mode == :fence and is_nil(local.worker_job_document) and is_nil(local.worker_job_digest) and
         is_nil(local.coop_session_id) and is_nil(run.submit_revision) and
         is_nil(run.coop_turn_id),
       do: historical_cleanup_session(claim, run, local, settings),
       else: locate_and_bind_session(claim, run, local, settings, mode)
  end

  # Only a succeeded operation at this run's exact key can recover an unbound
  # session. A direct fence response is not proof, and this path never starts
  # work. No operation at that key means the attempt ended before its session
  # was asked for, and nothing exists to stop: read as unresolved, it held its
  # conversation for about a day (2026-10-04 review).
  defp historical_cleanup_session(claim, run, local, settings) do
    case call(claim, settings, :operation_by_key, [Learning.operation_key(run, :create)]) do
      :not_found -> {:error, :learning_session_never_created}
      operation -> bind_created_session(claim, run, local, operation, settings)
    end
  end

  defp bind_created_session(claim, run, local, operation, settings) do
    with {:ok,
          %{
            "method" => "CreateRemoteSession",
            "state" => "succeeded",
            "resource_type" => "session",
            "resource_id" => id
          }}
         when is_binary(id) and byte_size(id) in 1..1024 <- operation,
         {:ok, %{"id" => ^id, "state" => state, "revision" => revision} = remote} <-
           call(claim, settings, :get_session, [id]),
         true <- remote["external_ref"] == Work.Session.coop_task_ref(local),
         true <- valid_session_state?(state, revision),
         {:ok, saved} <- Batches.with_lease(claim, fn -> FleetSession.bind(run, id) end),
         :ok <- CoopFleet.JobAuthority.exact_cleanup_receipt(saved, remote) do
      {:ok, remote}
    else
      {:error, reason} -> {:error, reason}
      _unproven -> {:error, :learning_remote_unresolved}
    end
  end

  defp locate_and_bind_session(claim, run, local, settings, mode) do
    with :ok <- prepare_session(claim, run, settings, mode),
         {:ok, %{} = session} <-
           locate_session(claim, run, local.coop_session_id, settings, mode),
         :ok <- exact_session(session, local, mode),
         {:ok, _} <- Batches.with_lease(claim, fn -> FleetSession.bind(run, session["id"]) end) do
      {:ok, session}
    end
  end

  # Freeze before the first remote read too: if that read stays unreachable until
  # the attempt expires, cleanup still needs the exact create document to fence.
  defp prepare_session(claim, run, settings, :create) do
    with :ok <-
           Coop.API.prepare_create_session(
             settings.api,
             settings.client,
             Learning.operation_key(run, :create),
             run.policy,
             FleetSession.external_ref(run),
             nil
           ),
         {:ok, _} <- Batches.renew(claim, settings.lease_seconds),
         do: :ok
  end

  defp prepare_session(_claim, _run, _settings, :fence), do: :ok

  # Retained messages go only to an isolated session. Its saved job fixed that
  # authority when the session was created, so no retry of this attempt can
  # change it: stop the attempt before anything is disclosed.
  defp disclosable(claim, run, session, settings) do
    if Coop.Documents.isolated_session?(session) do
      :ok
    else
      case stop(claim, run, :learning_session_not_isolated, settings) do
        {:ok, :stopped} -> {:error, :learning_session_not_isolated}
        other -> other
      end
    end
  end

  # A worker session this attempt can no longer use: its placement ended and
  # learning never replaces a session (the fleet recovers only its bound holder),
  # or its identity is not this run's. The
  # submission revision is frozen before any turn is sent, so without one there
  # is no model turn to wait for, and closing costs a start, never a model call.
  defp unaddressable?(run, reason),
    do: is_nil(run.submit_revision) and is_nil(run.coop_turn_id) and unaddressable?(reason)

  defp unaddressable?({:coop_session_replacement_required, _session, _generation}), do: true

  defp unaddressable?(reason),
    do: reason in [:learning_session_authority_conflict, :learning_session_identity_conflict]

  defp unaddressable_code({reason, _session, _generation}), do: Atom.to_string(reason)
  defp unaddressable_code(reason), do: Atom.to_string(reason)

  defp locate_session(claim, run, nil, settings, mode) do
    key = Learning.operation_key(run, :create)
    action = if mode == :create, do: :create_session, else: :fence_create_session

    operation(
      claim,
      settings,
      key,
      "CreateRemoteSession",
      "session",
      fn ->
        call(claim, settings, action, [key, run.policy, FleetSession.external_ref(run), nil])
      end,
      &call(claim, settings, :get_session, [&1]),
      :create
    )
  end

  defp locate_session(claim, _run, id, settings, _mode),
    do: call(claim, settings, :get_session, [id])

  defp remote_turn(claim, run, session, settings, mode) do
    run = Repo.fetch!(LearningRun.Query.by_id(run.id))

    result =
      if run.coop_turn_id do
        with {:ok, turn} <- call(claim, settings, :get_turn, [session["id"], run.coop_turn_id]),
             :ok <- exact_turn(turn, session["id"], run.coop_turn_id),
             do: {:ok, turn}
      else
        locate_turn(claim, run, session, settings, mode)
      end

    with {:ok, %{} = turn} <- result,
         {:ok, _} <- observe(claim, run, session, turn),
         do: {:ok, turn}
  end

  # Every observed learning turn is metered under the batch lease, like admission
  # under its input lock.
  defp observe(claim, run, session, turn) do
    Batches.with_lease(claim, fn ->
      local = Repo.fetch!(Work.Session.Query.by_learning_run_id(run.id))

      Ryker.Accounting.observe_learning_in_transaction(
        claim.batch,
        run,
        local.id,
        turn,
        session,
        Repo.now!()
      )
    end)
  end

  defp locate_turn(claim, run, session, settings, mode) do
    key = Learning.operation_key(run, :submit)
    # Freeze before any submit. A stop before this freeze still fences the exact
    # current revision; the stale worker must reacquire this batch to submit.
    with {:ok, frozen} <- freeze_revision(claim, run, session, mode),
         {:ok, %{} = turn} <-
           operation(
             claim,
             settings,
             key,
             "SubmitTurn",
             "turn",
             fn -> dispatch_turn(claim, frozen, session, settings, mode) end,
             &call(claim, settings, :get_turn, [session["id"], &1]),
             :submit
           ),
         :ok <- exact_turn(turn, session["id"], nil),
         {:ok, _} <- Learning.bind_turn(run.id, session["id"], turn["id"], claim) do
      {:ok, turn}
    end
  end

  defp dispatch_turn(claim, frozen, session, settings, mode) do
    action = if mode == :submit, do: :submit_frozen_turn, else: :fence_frozen_turn

    with :ok <- authorize_disclosure(claim, frozen, mode),
         {:ok, _} <- requested(claim, frozen, session, mode) do
      call(claim, settings, action, [
        session["id"],
        Learning.operation_key(frozen, :submit),
        frozen.submit_revision,
        submission(frozen),
        nil,
        []
      ])
    end
  end

  # A lost submit response must not lose the target this attempt is spending on.
  defp requested(_claim, _frozen, _session, :fence), do: {:ok, :fenced}

  defp requested(claim, frozen, session, :submit),
    do: observe(claim, frozen, session, %{"state" => "requested"})

  defp freeze_revision(claim, %{submit_revision: revision} = run, _session, _mode)
       when is_integer(revision) do
    case Batches.authorize(claim) do
      {:ok, _} -> {:ok, run}
      error -> error
    end
  end

  defp freeze_revision(claim, run, session, :submit),
    do: Learning.freeze_submit(run.id, session["revision"], claim)

  defp freeze_revision(_claim, _run, _session, :fence), do: {:ok, :never_submitted}

  defp authorize_disclosure(claim, run, :submit) do
    case Learning.authorize(run.id, claim) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp authorize_disclosure(_claim, _run, :fence), do: :ok

  defp process_turn(claim, run, session, %{"state" => "awaiting_validation"} = turn, settings) do
    # Coop records the selected target on the current session, not the turn DTO.
    producer = Map.take(turn, ~w(id session_id)) |> Map.put("target", session["target"])

    with {:ok, saved} <- Learning.record_candidate(run.id, turn, producer, claim),
         {:ok, _} <- Learning.check_candidate(saved.id, claim),
         key =
           "ryker:learning:validate:#{run.id}:a#{saved.candidate_attempt}:#{turn["candidate"]["sha256"]}",
         {:ok, _} <-
           call(claim, settings, :validate_frozen_candidate, [
             session["id"],
             turn["id"],
             key,
             saved.candidate_attempt,
             turn["candidate"]["sha256"],
             :accept
           ]),
         {:ok, completed} <- call(claim, settings, :get_turn, [session["id"], turn["id"]]),
         {:ok, _} <- observe(claim, run, session, completed) do
      if completed["state"] == "completed",
        do: complete(claim, saved, completed),
        else: {:ok, :waiting}
    else
      {:error, reason} = error
      when reason in [
             :invalid_learning_result,
             :learning_match_required,
             :learning_source_stale,
             :learning_context_stale,
             :learning_capacity_exceeded,
             :knowledge_anchor_not_sourced,
             :knowledge_target_unavailable,
             :knowledge_match_ambiguous
           ] ->
        # The retained candidate and exact alternatives survive this generation.
        # Semantic retries get a fresh briefing, never an in-turn prose patch.
        case stop(claim, Repo.fetch!(LearningRun.Query.by_id(run.id)), reason, settings) do
          {:ok, :stopped} -> error
          other -> other
        end

      other ->
        other
    end
  end

  defp process_turn(claim, run, _session, %{"state" => "completed"} = turn, _settings),
    do: complete(claim, run, turn)

  defp process_turn(claim, run, session, %{"state" => state} = turn, _settings)
       when state in @terminal do
    reason =
      if state == "failed" and turn["error_code"] == "output_contract_failed",
        do: :output_contract_failed,
        else: :learning_provider_failed

    receipt = %{
      "session_id" => turn["session_id"],
      "turn_id" => turn["id"],
      "target" => session["target"],
      "prompt_sha256" => run.prompt_sha256,
      "state" => state,
      "error_code" => turn["error_code"],
      "finished_at" => turn["finished_at"]
    }

    with {:ok, _} <- Learning.fail(run.id, reason, receipt, claim),
         do: {:error, reason}
  end

  defp process_turn(_claim, _run, _session, %{"state" => state}, _settings)
       when state in ~w(queued running pending), do: {:ok, :waiting}

  defp process_turn(_, _, _, _, _), do: {:error, :learning_remote_protocol_error}

  defp complete(claim, run, turn) do
    result =
      with {:ok, _} <- Learning.confirm_candidate(run.id, turn, claim),
           do: Learning.apply_result(run.id, claim)

    # A competing update or withdrawn source can reject application after Coop
    # finishes. That is not remote uncertainty: preserve the terminal proof now.
    with {:ok, _} <- Learning.record_stop(run.id, turn, claim) do
      case result do
        {:ok, applied} ->
          {:ok, {:applied, applied}}

        {:error, reason} ->
          Learning.end_attempt(run.id, reason, claim)
          {:error, reason}
      end
    end
  end

  def stop(claim, run, reason, settings) do
    with {:ok, run} <- Learning.end_attempt(run.id, reason, claim) do
      stop_remote(claim, run, settings)
    end
  end

  @doc "Close an attempt none of whose turns can still be running, on local proof alone."
  def expire(claim, run, closed_after_seconds),
    do: run.id |> Learning.record_expired_stop(closed_after_seconds, claim) |> stopped()

  defp stop_remote(_claim, %{remote_stopped_at: %DateTime{}}, _settings), do: {:ok, :stopped}

  defp stop_remote(claim, run, settings) do
    with {:ok, %{} = session} <- remote_session(claim, run, settings, :fence),
         {:ok, turn} when is_map(turn) or turn == :never_submitted <-
           stopped_turn(claim, run, session, settings) do
      settle_stopped_turn(claim, run, session, turn, settings)
    else
      {:error, {:operation_failed, phase, operation}} ->
        Learning.record_fenced_absence(
          run.id,
          phase,
          Learning.operation_key(run, phase),
          operation,
          claim
        )
        |> stopped()

      {:error, :learning_session_never_created} ->
        run.id |> Learning.record_uncreated_stop(claim) |> stopped()

      {:error, reason} ->
        # An unreachable worker proves nothing and keeps reconciling; a session
        # that can never be addressed again leaves only the local proof.
        if unaddressable?(run, reason) do
          run.id
          |> Learning.record_unaddressable_stop(unaddressable_code(reason), claim)
          |> stopped()
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  defp settle_stopped_turn(claim, run, session, :never_submitted, _settings) do
    # No submission revision was persisted, so no conforming worker can
    # have sent a turn. Still fence create, which was frozen before I/O.
    Learning.record_unsubmitted_stop(run.id, session["id"], claim) |> stopped()
  end

  defp settle_stopped_turn(claim, run, _session, %{"state" => state} = turn, _settings)
       when state in @terminal,
       do: Learning.record_stop(run.id, turn, claim) |> stopped()

  defp settle_stopped_turn(claim, run, session, turn, settings) do
    key = Learning.operation_key(run, :cancel) <> ":r#{session["revision"]}"

    with {:ok, _} <-
           call(claim, settings, :cancel_turn, [
             session["id"],
             turn["id"],
             key,
             session["revision"]
           ]),
         do: {:ok, :waiting}
  end

  defp stopped_turn(_claim, %{submit_revision: nil, coop_turn_id: nil}, _session, _settings),
    do: {:ok, :never_submitted}

  defp stopped_turn(claim, run, session, settings),
    do: remote_turn(claim, run, session, settings, :fence)

  defp stopped({:ok, _}), do: {:ok, :stopped}
  defp stopped(error), do: error

  defp operation(claim, settings, key, method, type, start, fetch, phase) do
    result =
      case call(claim, settings, :operation_by_key, [key]) do
        :not_found -> start.()
        other -> other
      end

    case result do
      {:ok, %{"operation" => op}} ->
        operation_result(op, method, type, fetch, phase)

      {:ok, %{"method" => _} = op} ->
        operation_result(op, method, type, fetch, phase)

      {:ok, resource} when is_map(resource) ->
        case resource[type] do
          %{} = value -> {:ok, value}
          _ -> {:error, :learning_remote_protocol_error}
        end

      other ->
        other
    end
  end

  defp operation_result(
         %{
           "method" => method,
           "state" => "succeeded",
           "resource_type" => type,
           "resource_id" => id
         },
         method,
         type,
         fetch,
         _phase
       )
       when is_binary(id), do: fetch.(id)

  defp operation_result(%{"method" => method, "state" => "failed"} = op, method, _, _, phase),
    do: {:error, {:operation_failed, phase, op}}

  defp operation_result(%{"method" => method, "state" => state}, method, _, _, _)
       when state in @pending,
       do: {:ok, :waiting}

  defp operation_result(_, _, _, _, _), do: {:error, :learning_remote_unresolved}

  defp exact_session(
         %{
           "id" => id,
           "state" => state,
           "revision" => revision
         } = remote,
         local,
         mode
       ) do
    authority =
      if mode == :fence,
        do: CoopFleet.JobAuthority.exact_cleanup_receipt(local, remote),
        else: CoopFleet.JobAuthority.exact_receipt(local, remote)

    if is_binary(id) and byte_size(id) in 1..1024 and local.coop_session_id in [nil, id] and
         authority == :ok and valid_session_state?(state, revision),
       do: :ok,
       else: {:error, :learning_session_authority_conflict}
  end

  defp exact_session(_, _, _), do: {:error, :learning_remote_protocol_error}

  defp valid_session_state?(state, revision),
    do: state in ~w(open exhausted closed discarded) and is_integer(revision) and revision > 0

  defp exact_turn(turn, session_id, expected) do
    if Coop.Documents.exact_turn?(turn, session_id, expected),
      do: :ok,
      else: {:error, :learning_remote_identity_conflict}
  end

  defp call(claim, settings, operation, arguments) do
    with {:ok, _} <- Batches.renew(claim, settings.lease_seconds) do
      apply(settings.api, operation, [settings.client | arguments])
    end
  end

  defp submission(run),
    do: %{
      "contract_version" => "conversation-learning-v2",
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => run.output_schema,
      "prompt" => run.prompt
    }
end
