defmodule Ryker.Improvement.Executor do
  @moduledoc """
  One resumable step of an analysis run through Coop, after the learning
  executor (`Ryker.Learning.Executor`): every remote effect is keyed by the
  frozen run (`Ryker.Improvement.Analyses.operation_key/2`), so a step
  repeated after a crash or a lost answer finds what it did before instead
  of doing it again.

  A step creates the run's session (or reads it), refuses to disclose
  anything to a session that is not an isolated read-only scratch, submits
  the frozen prompt once, and follows the turn. When the turn offers an
  answer, the host checks it against the contract (`Ryker.Improvement.Prompt.parse/1`)
  before telling Coop to accept it, as learning does; an answer that fails
  the check, or that the host cannot keep at all
  (`Ryker.Improvement.Analyses.record_candidate/4`), ends the run, and the
  next start gets a fresh prompt that says so.

  Nothing is abandoned while its outcome is unknown: a create or a submit
  Coop has not finished is waited for, a turn past its time is cancelled and
  waited for, and only a day after the run's window (no Coop turn outlives
  one) does local proof alone close it. So a lost answer never buys a second
  model call.
  """
  alias Ryker.Coop
  alias Ryker.CoopFleet
  alias Ryker.Improvement.{Analyses, FleetSession, Prompt}
  alias Ryker.Repo
  alias Ryker.Work

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @pending ~w(reserved running)
  @waiting ~w(queued running pending requested starting)
  # Coop's MaxTurnTimeout: a session policy cannot allow a longer turn.
  @longest_turn_seconds 24 * 3_600

  @doc """
  Moves the run on by one step: `{:ok, {:applied, candidate}}` once its
  diagnosis is saved, `{:ok, :waiting}` while Coop is still working,
  `{:ok, :stopped}` once the run ended without one and has stop proof, or an
  error for a step to try again.
  """
  def step(claim, run, settings) do
    run = run.id |> Analyses.current() |> forgotten(claim)

    cond do
      not is_nil(run.remote_stopped_at) ->
        {:ok, :stopped}

      expired?(run, @longest_turn_seconds + settings.execution_timeout_seconds) ->
        with {:ok, _run} <-
               Analyses.record_expired_stop(
                 claim,
                 run.id,
                 @longest_turn_seconds + settings.execution_timeout_seconds
               ),
             do: {:ok, :stopped}

      true ->
        execute(claim, run, settings)
    end
  end

  # A person forgot something the run's prompt quotes while it was out: its
  # words are erased, so it only ever stops from here, never sends.
  defp forgotten(%{prompt: nil, status: status} = run, claim)
       when status in [:prepared, :responded] do
    case Analyses.end_attempt(claim, run.id, :improvement_forgotten) do
      {:ok, ended} -> ended
      {:error, _reason} -> run
    end
  end

  defp forgotten(run, _claim), do: run

  defp execute(claim, run, settings) do
    case remote_session(claim, run, settings) do
      {:ok, %{} = session} ->
        session_step(claim, run, session, settings)

      {:error, reason} ->
        if unaddressable?(run, reason),
          do: give_up_session(claim, run, reason),
          else: {:error, reason}

      other ->
        other
    end
  end

  defp session_step(claim, run, session, settings) do
    cond do
      not isolated_session?(session) ->
        stop(claim, run, session, :improvement_session_not_isolated, settings)

      # The worker closed or used up the session before its turn was sent:
      # nothing can be sent to it, and a new start gets a new one.
      session["state"] != "open" and is_nil(run.coop_turn_id) and not ended?(run) ->
        stop(claim, run, session, :improvement_session_unaddressable, settings)

      true ->
        turn_step(claim, run, session, settings)
    end
  end

  # A session this run can no longer use: the worker holding it went away and
  # the fleet never replaces a session, or it is not this run's. The submit
  # revision is frozen before anything is sent, so without one no turn exists
  # to wait for, and giving up costs a start, never a model call.
  defp unaddressable?(run, reason),
    do: is_nil(run.submit_revision) and is_nil(run.coop_turn_id) and unaddressable?(reason)

  defp unaddressable?({:coop_session_replacement_required, _session, _generation}), do: true

  defp unaddressable?(reason) do
    reason in [:improvement_session_authority_conflict, :improvement_session_identity_conflict]
  end

  defp give_up_session(claim, run, reason) do
    code =
      case reason do
        {code, _session, _generation} -> Atom.to_string(code)
        code -> Atom.to_string(code)
      end

    with {:ok, _ended} <- Analyses.end_attempt(claim, run.id, :improvement_session_unaddressable),
         {:ok, _stopped} <- Analyses.record_unaddressable_stop(claim, run.id, code),
         do: {:ok, :stopped}
  end

  # -- The session -------------------------------------------------------------------

  defp remote_session(claim, run, settings) do
    {:ok, local} = FleetSession.fetch_for_run(run)

    case local.coop_session_id do
      nil -> create_session(claim, run, local, settings)
      id -> located_session(call(claim, settings, :get_session, [id]), local)
    end
  end

  defp create_session(claim, run, local, settings) do
    key = Analyses.operation_key(run, :create)

    result =
      case call(claim, settings, :operation_by_key, [key]) do
        :not_found when run.status in [:rejected, :stale] ->
          # Ended before its session was asked for: nothing exists to stop.
          with {:ok, _run} <- Analyses.record_uncreated_stop(claim, run.id),
               do: {:ok, :stopped}

        :not_found ->
          with :ok <-
                 Coop.API.prepare_create_session(
                   settings.api,
                   settings.client,
                   key,
                   run.policy,
                   FleetSession.external_ref(run),
                   nil
                 ) do
            call(claim, settings, :create_session, [
              key,
              run.policy,
              FleetSession.external_ref(run),
              nil
            ])
          end

        other ->
          other
      end

    case operation(result, "CreateRemoteSession", "session") do
      {:ok, %{"id" => id} = session} when is_binary(id) ->
        with {:ok, _bound} <- bind(claim, run, id),
             do: located_session({:ok, session}, Repo.one!(Work.Session.Query.by_id(local.id)))

      {:resource, id} ->
        with {:ok, _bound} <- bind(claim, run, id) do
          located_session(
            call(claim, settings, :get_session, [id]),
            Repo.one!(Work.Session.Query.by_id(local.id))
          )
        end

      {:failed, operation} ->
        with {:ok, _run} <- Analyses.record_failed_operation(claim, run.id, :create, operation),
             do: {:ok, :stopped}

      other ->
        other
    end
  end

  defp bind(claim, run, id), do: Analyses.with_lease(claim, fn -> FleetSession.bind(run, id) end)

  defp located_session(
         {:ok, %{"id" => id, "state" => state, "revision" => revision} = remote},
         local
       )
       when is_binary(id) and is_integer(revision) and revision > 0 do
    if local.coop_session_id == id and state in ~w(open exhausted closed discarded) and
         CoopFleet.JobAuthority.exact_receipt(local, remote) == :ok,
       do: {:ok, remote},
       else: {:error, :improvement_session_authority_conflict}
  end

  defp located_session({:ok, _remote}, _local), do: {:error, :improvement_remote_protocol_error}
  defp located_session(other, _local), do: other

  # Retained messages go only to an isolated session, as learning's do.
  defp isolated_session?(session) do
    is_nil(session["controller_tools_digest"]) and is_nil(session["workspace_task"]) and
      session["repository_read_only"] == true and session["project_env"] == false and
      session["project_mcp"] == false and Map.get(session, "companions", []) == []
  end

  # -- The turn ----------------------------------------------------------------------

  # A run that was ended (for an answer that failed the check, or a turn past
  # its time) only follows its turn to a stop; it never accepts or submits.
  defp turn_step(claim, run, session, settings) do
    case remote_turn(claim, run, session, settings) do
      {:ok, %{} = turn} ->
        run = Analyses.current(run.id)

        if ended?(run),
          do: settle_stopped(claim, run, session, turn, settings),
          else: process_turn(claim, run, session, turn, settings)

      other ->
        other
    end
  end

  defp ended?(run), do: run.status in [:rejected, :stale]

  defp remote_turn(claim, run, session, settings) do
    result =
      case run.coop_turn_id do
        nil ->
          submit(claim, run, session, settings)

        turn_id ->
          with {:ok, turn} <- call(claim, settings, :get_turn, [session["id"], turn_id]),
               :ok <- exact_turn(turn, session["id"], turn_id),
               do: {:ok, turn}
      end

    with {:ok, %{} = turn} <- result,
         {:ok, _metered} <- observe(claim, run, session, turn),
         do: {:ok, turn}
  end

  # The session revision is frozen before anything is sent. A submit Coop has
  # no record of was never sent, so an ended run stops on that proof instead
  # of sending it now.
  defp submit(claim, run, session, settings) do
    key = Analyses.operation_key(run, :submit)

    result =
      case call(claim, settings, :operation_by_key, [key]) do
        :not_found ->
          if ended?(run),
            do: unsubmitted(claim, run, session),
            else: send_turn(claim, run, session, settings, key)

        other ->
          other
      end

    case operation(result, "SubmitTurn", "turn") do
      {:ok, %{"id" => id} = turn} when is_binary(id) ->
        bound_turn(claim, run, session, turn)

      {:resource, id} ->
        with {:ok, turn} <- call(claim, settings, :get_turn, [session["id"], id]),
             do: bound_turn(claim, run, session, turn)

      {:failed, operation} ->
        with {:ok, _run} <- Analyses.record_failed_operation(claim, run.id, :submit, operation),
             do: {:ok, :stopped}

      other ->
        other
    end
  end

  defp send_turn(claim, run, session, settings, key) do
    with {:ok, frozen} <-
           Analyses.freeze_submit(claim, run.id, run.submit_revision || session["revision"]),
         {:ok, _metered} <- observe(claim, frozen, session, %{"state" => "requested"}) do
      call(claim, settings, :submit_frozen_turn, [
        session["id"],
        key,
        frozen.submit_revision,
        submission(frozen),
        nil,
        []
      ])
    end
  end

  defp unsubmitted(claim, run, session) do
    with {:ok, _run} <- Analyses.record_unsubmitted_stop(claim, run.id, session["id"]),
         do: {:ok, :stopped}
  end

  defp bound_turn(claim, run, session, turn) do
    with :ok <- exact_turn(turn, session["id"], nil),
         {:ok, _run} <- Analyses.bind_turn(claim, run.id, session["id"], turn["id"]),
         do: {:ok, turn}
  end

  defp submission(run),
    do: %{
      "contract_version" => Prompt.contract_version(),
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => run.output_schema,
      "prompt" => run.prompt
    }

  # An offered answer the host cannot keep, or one outside the contract, ends
  # the run: reading the same turn again would only offer it again.
  defp process_turn(claim, run, session, %{"state" => "awaiting_validation"} = turn, settings) do
    # Coop records the selected target on the session, not on the turn.
    producer = turn |> Map.take(~w(id session_id)) |> Map.put("target", session["target"])

    with {:ok, saved} <- Analyses.record_candidate(claim, run.id, turn, producer),
         {:ok, _diagnosis} <- Prompt.parse(saved.result) do
      accept(claim, saved, session, turn, settings)
    else
      {:error, :invalid_improvement_result} ->
        stop(claim, run, session, :invalid_improvement_result, settings)

      # A person forgot what the prompt quotes while the answer was read, after
      # this step's own check (`forgotten/2`): the answer is not kept.
      {:error, :improvement_forgotten} ->
        stop(claim, run, session, :improvement_forgotten, settings)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_turn(claim, run, _session, %{"state" => "completed"} = turn, _settings),
    do: complete(claim, run, turn)

  defp process_turn(claim, run, _session, %{"state" => state} = turn, _settings)
       when state in @terminal do
    reason =
      if state == "failed" and turn["error_code"] == "output_contract_failed",
        do: :output_contract_failed,
        else: :improvement_provider_failed

    with {:ok, _run} <- Analyses.fail(claim, run.id, reason, turn), do: {:ok, :stopped}
  end

  defp process_turn(claim, run, session, %{"state" => state}, settings) when state in @waiting do
    if expired?(run, settings.execution_timeout_seconds),
      do: stop(claim, run, session, :improvement_execution_timeout, settings),
      else: {:ok, :waiting}
  end

  defp process_turn(_claim, _run, _session, _turn, _settings),
    do: {:error, :improvement_remote_protocol_error}

  defp accept(claim, run, session, turn, settings) do
    key =
      "ryker:improvement:validate:#{run.id}:a#{run.candidate_attempt}:#{turn["candidate"]["sha256"]}"

    with {:ok, _accepted} <-
           call(claim, settings, :validate_frozen_candidate, [
             session["id"],
             turn["id"],
             key,
             run.candidate_attempt,
             turn["candidate"]["sha256"],
             :accept
           ]),
         {:ok, completed} <- call(claim, settings, :get_turn, [session["id"], turn["id"]]),
         {:ok, _metered} <- observe(claim, run, session, completed) do
      if completed["state"] == "completed",
        do: complete(claim, run, completed),
        else: {:ok, :waiting}
    end
  end

  # The turn is over and its answer accepted: the diagnosis is saved with the
  # turn's stop proof, which gives the lease back. An answer that cannot be
  # saved ends the attempt, and the finished turn is still its stop proof.
  defp complete(claim, run, turn) do
    result =
      with {:ok, _confirmed} <- Analyses.confirm_candidate(claim, run.id, turn),
           do: Analyses.apply_result(claim, run.id, turn)

    case result do
      {:ok, candidate} ->
        {:ok, {:applied, candidate}}

      {:error, reason} ->
        with {:ok, _ended} <- Analyses.end_attempt(claim, run.id, reason),
             {:ok, _stopped} <- Analyses.record_stop(claim, run.id, turn),
             do: {:ok, :stopped}
    end
  end

  # -- Stopping ----------------------------------------------------------------------

  @doc """
  Ends the run for `reason` and stops what it started at the worker: a turn
  never submitted stops on that proof, a finished one on its terminal state,
  and a running one is cancelled and waited for.
  """
  def stop(claim, run, session, reason, settings) do
    with {:ok, run} <- Analyses.end_attempt(claim, run.id, reason) do
      if is_nil(run.remote_stopped_at),
        do: turn_step(claim, run, session, settings),
        else: {:ok, :stopped}
    end
  end

  defp settle_stopped(claim, run, session, turn, settings) do
    if turn["state"] in @terminal do
      with {:ok, _run} <- Analyses.record_stop(claim, run.id, turn), do: {:ok, :stopped}
    else
      key = Analyses.operation_key(run, :cancel) <> ":r#{session["revision"]}"

      with {:ok, _cancelled} <-
             call(claim, settings, :cancel_turn, [
               session["id"],
               turn["id"],
               key,
               session["revision"]
             ]),
           do: {:ok, :waiting}
    end
  end

  # -- Coop --------------------------------------------------------------------------

  # A create or submit answers with its resource, with an operation that may
  # still be running, or, looked up by key, with the operation itself.
  defp operation({:ok, %{"operation" => operation}}, method, type),
    do: operation_state(operation, method, type)

  defp operation({:ok, %{"method" => _method} = operation}, method, type),
    do: operation_state(operation, method, type)

  defp operation({:ok, resource}, _method, type) when is_map(resource) do
    case resource[type] do
      %{} = value -> {:ok, value}
      _other -> {:error, :improvement_remote_protocol_error}
    end
  end

  defp operation(other, _method, _type), do: other

  defp operation_state(
         %{
           "method" => method,
           "state" => "succeeded",
           "resource_type" => type,
           "resource_id" => id
         },
         method,
         type
       )
       when is_binary(id),
       do: {:resource, id}

  defp operation_state(%{"method" => method, "state" => "failed"} = operation, method, _type),
    do: {:failed, operation}

  defp operation_state(%{"method" => method, "state" => state}, method, _type)
       when state in @pending,
       do: {:ok, :waiting}

  defp operation_state(_operation, _method, _type), do: {:error, :improvement_remote_unresolved}

  defp exact_turn(%{"id" => id, "session_id" => session_id}, session_id, expected)
       when is_binary(id) and byte_size(id) in 1..1024 and (is_nil(expected) or expected == id),
       do: :ok

  defp exact_turn(_turn, _session_id, _expected),
    do: {:error, :improvement_remote_identity_conflict}

  # Every observed turn is metered under the lease, as learning's are.
  defp observe(claim, run, session, turn) do
    Analyses.with_lease(claim, fn ->
      candidate = Analyses.lock_owned_in_transaction!(claim)
      {:ok, local} = FleetSession.fetch_for_run(run)

      Ryker.Accounting.observe_improvement_in_transaction(
        candidate,
        run,
        local.id,
        turn,
        session,
        Repo.now!()
      )
    end)
  end

  defp call(claim, settings, operation, arguments) do
    with {:ok, _renewed} <- Analyses.renew(claim, settings.lease_seconds) do
      apply(settings.api, operation, [settings.client | arguments])
    end
  end

  defp expired?(run, seconds) do
    %{rows: [[expired]]} =
      Repo.query!(
        "SELECT $1::timestamptz + ($2 * interval '1 second') <= clock_timestamp()",
        [run.started_at, seconds]
      )

    expired
  end
end
