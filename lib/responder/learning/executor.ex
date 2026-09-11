defmodule Responder.Learning.Executor do
  @moduledoc "One resumable, bounded learning step. All remote effects use the frozen run identity."
  alias Responder.Learning.{Batches, FleetSession}
  alias Responder.{Repo, State.Learning}
  alias Responder.Work.Session

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @pending ~w(reserved running)

  def step(claim, run, settings) do
    result =
      case Learning.authorize(run.id, claim) do
        {:ok, run} ->
          if expired?(run, settings),
            do: stop(claim, run, :learning_execution_timeout, settings),
            else: execute(claim, run, settings)

        {:error, :learning_lease_lost} = error ->
          error

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
    with {:ok, %{} = session} <- remote_session(claim, run, settings, :create),
         {:ok, %{} = turn} <- remote_turn(claim, run, session, settings, :submit) do
      process_turn(claim, run, session, turn, settings)
    end
  end

  defp remote_session(claim, run, settings, mode) do
    local = Repo.get_by!(Session, learning_run_id: run.id)

    result = locate_session(claim, run, local.coop_session_id, settings, mode)

    with {:ok, %{} = session} <- result,
         :ok <- exact_session(session, run, local.coop_session_id),
         {:ok, _} <- Batches.with_lease(claim, fn -> FleetSession.bind(run, session["id"]) end) do
      {:ok, session}
    end
  end

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
      fn id -> call(claim, settings, :get_session, [id]) end,
      :create
    )
  end

  defp locate_session(claim, _run, id, settings, _mode),
    do: call(claim, settings, :get_session, [id])

  defp remote_turn(claim, run, session, settings, mode) do
    run = Repo.get!(Responder.State.LearningRun, run.id)

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
      local = Repo.get_by!(Session, execution_kind: :learning, learning_run_id: run.id)

      Responder.Accounting.observe_learning_in_transaction(
        claim.batch,
        run,
        local.id,
        turn,
        session,
        DateTime.utc_now()
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
             fn id -> call(claim, settings, :get_turn, [session["id"], id]) end,
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
           "responder:learning:validate:#{run.id}:a#{saved.candidate_attempt}:#{turn["candidate"]["sha256"]}",
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
        case stop(claim, Repo.get!(Responder.State.LearningRun, run.id), reason, settings) do
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

        {:error, reason} = error ->
          Learning.end_attempt(run.id, reason, claim)
          error
      end
    end
  end

  def stop(claim, run, reason, settings) do
    with {:ok, run} <- Learning.end_attempt(run.id, reason, claim) do
      stop_remote(claim, run, settings)
    end
  end

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
           "policy" => policy,
           "policy_digest" => digest,
           "external_ref" => external,
           "state" => state,
           "revision" => revision
         } = session,
         run,
         expected
       ) do
    if is_binary(id) and byte_size(id) in 1..1024 and expected in [nil, id] and
         policy == run.policy and
         digest == run.policy_digest and external == FleetSession.external_ref(run) and
         valid_session_state?(state, revision) and isolated_session?(session),
       do: :ok,
       else: {:error, :learning_session_authority_conflict}
  end

  defp exact_session(_, _, _), do: {:error, :learning_remote_protocol_error}

  defp valid_session_state?(state, revision),
    do: state in ~w(open exhausted closed discarded) and is_integer(revision) and revision > 0

  defp isolated_session?(session),
    do:
      is_nil(session["responder_binding_digest"]) and is_nil(session["workspace_task"]) and
        session["repository_read_only"] == true and
        session["project_env"] == false and session["project_mcp"] == false and
        Map.get(session, "companions", []) == []

  defp exact_turn(%{"id" => id, "session_id" => sid}, sid, expected)
       when is_binary(id) and byte_size(id) in 1..1024 and (is_nil(expected) or expected == id),
       do: :ok

  defp exact_turn(_, _, _), do: {:error, :learning_remote_identity_conflict}

  defp call(claim, settings, operation, arguments) do
    with {:ok, _} <- Batches.renew(claim, settings.lease_seconds) do
      apply(settings.api, operation, [settings.client | arguments])
    end
  end

  defp expired?(run, settings) do
    %{rows: [[expired]]} =
      Repo.query!(
        "SELECT $1::timestamptz + ($2 * interval '1 second') <= clock_timestamp()",
        [run.started_at, settings.execution_timeout_seconds]
      )

    expired
  end

  def submission(run),
    do: %{
      "contract_version" => "conversation-learning-v2",
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => run.output_schema,
      "prompt" => run.prompt
    }
end
