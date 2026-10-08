defmodule Ryker.Coop.RunStep do
  @moduledoc """
  One resumable step of a background model run through Coop, shared by
  self-analysis (`Ryker.Improvement.Executor`) and repository reading
  (`Ryker.RepositoryKnowledge.Executor`). Every remote effect is keyed by the
  frozen run (the store's `operation_key/2`), so a step repeated after a crash
  or a lost answer finds what it did before instead of doing it again.

  A step creates the run's session (or reads it), refuses to disclose anything
  to a session that is not an isolated read-only scratch, submits the frozen
  prompt once, and follows the turn. When the turn offers an answer, the
  store keeps it and the lane checks it (`c:check/4`) before Coop is told to
  accept it; an answer that fails, or one the store refuses
  (`c:refused_candidate?/1`), ends the run, and the next start is told why.

  Nothing is abandoned while its outcome is unknown: a create or a submit
  Coop has not finished is waited for, a turn past its time is cancelled and
  waited for, and only a day after the run's window (no Coop turn outlives
  one) does local proof alone close it. So a lost answer never buys a second
  model call.

  The two lanes ran this protocol as two copies until 2026-10-08, the second
  written from the first.
  """
  alias Ryker.Coop
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.Work

  @enforce_keys [:lane, :store, :claim, :context, :settings]
  defstruct @enforce_keys

  @typedoc "What a lane's check reads beside the run: repository reading's repository."
  @type context :: term()
  @typedoc "A step's answer: applied, waiting on Coop, stopped with proof, or an error to retry."
  @type result :: {:ok, {:applied, term()}} | {:ok, :waiting} | {:ok, :stopped} | {:error, term()}

  @doc "The run's custody (`Ryker.Coop.RunStep.Store`)."
  @callback store() :: module()

  @doc "The run's local session: `fetch_for_run/1`, `external_ref/1` and `bind/2`."
  @callback fleet_session() :: module()

  @doc "The repository source a run's session reads, or nil for none."
  @callback source(run :: struct()) :: map() | nil

  @doc """
  The lane's own name for one of the protocol's errors, so the codes stored
  and shown stay each lane's.
  """
  @callback error(kind :: atom()) :: atom()

  @doc "The key Coop accepts an answer under."
  @callback validate_key(run :: struct(), sha256 :: String.t()) :: String.t()

  @doc "The prompt contract a submission names."
  @callback contract_version() :: String.t()

  @doc "Meters one observed turn inside the lease's transaction."
  @callback observe_in_transaction(
              owner :: struct(),
              run :: struct(),
              session_id :: Ecto.UUID.t(),
              turn :: map(),
              session :: map(),
              now :: DateTime.t()
            ) :: {:ok, term()} | {:error, term()}

  @doc "Whether the store's refusal of an offered answer ends the run."
  @callback refused_candidate?(reason :: term()) :: boolean()

  @doc """
  The lane's check of an answer the store kept: `:ok` to accept it,
  `{:stop, reason}` to end the run, or `{:error, reason}` to try the step again.
  """
  @callback check(claim :: map(), run :: struct(), context(), settings :: map()) ::
              :ok | {:stop, atom()} | {:error, term()}

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @pending ~w(reserved running)
  @waiting ~w(queued running pending requested starting)
  # Coop's MaxTurnTimeout: a session policy cannot allow a longer turn.
  @longest_turn_seconds 24 * 3_600

  @doc """
  Moves `run`, as its store reads it now, on by one step for `lane`; see
  `t:result/0`.
  """
  @spec step(module(), map(), struct(), context(), map()) :: result()
  def step(lane, claim, run, context, settings) do
    run_step = %__MODULE__{
      lane: lane,
      store: lane.store(),
      claim: claim,
      context: context,
      settings: settings
    }

    window = @longest_turn_seconds + settings.execution_timeout_seconds

    cond do
      not is_nil(run.remote_stopped_at) ->
        {:ok, :stopped}

      Repo.passed?(run.started_at, window) ->
        with {:ok, _run} <- run_step.store.record_expired_stop(claim, run.id, window),
             do: {:ok, :stopped}

      true ->
        execute(run_step, run)
    end
  end

  @doc """
  `function`'s result, the run's lease renewed beside it meanwhile: preparing
  a large repository's session, or reading a tree and its files, can outlast
  the lease, and another worker would take the run over halfway (as Work's,
  2026-09-28).
  """
  @spec with_lease_kept(module(), map(), map(), (-> result)) :: result | {:error, term()}
        when result: term()
  def with_lease_kept(lane, claim, settings, function) do
    heartbeat = Task.async(fn -> keep_lease(lane, claim, settings) end)

    try do
      result = function.()
      send(heartbeat.pid, :stop)

      case Task.await(heartbeat, :infinity) do
        :ok -> result
        {:error, reason} -> {:error, reason}
      end
    after
      Task.shutdown(heartbeat, :brutal_kill)
    end
  end

  defp keep_lease(lane, claim, settings) do
    receive do
      :stop -> :ok
    after
      max(div(settings.lease_seconds * 1_000, 3), 100) ->
        case renew_lease(lane, claim, settings) do
          :ok -> keep_lease(lane, claim, settings)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A lease another worker holds comes back as an error, never an exception.
  # Every exception was read as a lost lease, so a dropped database
  # connection was logged as another worker taking the run (2026-10-04
  # review).
  defp renew_lease(lane, claim, settings) do
    case lane.store().renew(claim, settings.lease_seconds) do
      {:ok, _renewed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {lane.error(:lease_renewal_failed), error.__struct__}}
  end

  defp execute(run_step, run) do
    case remote_session(run_step, run) do
      {:ok, %{} = session} ->
        session_step(run_step, run, session)

      {:error, reason} ->
        if unaddressable?(run_step, run, reason),
          do: give_up_session(run_step, run, reason),
          else: {:error, reason}

      other ->
        other
    end
  end

  defp session_step(%__MODULE__{lane: lane} = run_step, run, session) do
    cond do
      not Coop.Documents.isolated_session?(session) ->
        stop(run_step, run, session, lane.error(:session_not_isolated))

      # The worker closed or used up the session before its turn was sent:
      # nothing can be sent to it, and a new start gets a new one.
      session["state"] != "open" and is_nil(run.coop_turn_id) and not ended?(run) ->
        stop(run_step, run, session, lane.error(:session_unaddressable))

      true ->
        turn_step(run_step, run, session)
    end
  end

  # A session this run can no longer use: the worker holding it went away and
  # the fleet never replaces a session, or it is not this run's. The submit
  # revision is frozen before anything is sent, so without one no turn exists
  # to wait for, and giving up costs a start, never a model call.
  defp unaddressable?(%__MODULE__{lane: lane}, run, reason),
    do: is_nil(run.submit_revision) and is_nil(run.coop_turn_id) and unaddressable?(lane, reason)

  defp unaddressable?(_lane, {:coop_session_replacement_required, _session, _generation}),
    do: true

  defp unaddressable?(lane, reason) do
    reason in [lane.error(:session_authority_conflict), lane.error(:session_identity_conflict)]
  end

  defp give_up_session(%__MODULE__{lane: lane, store: store, claim: claim}, run, reason) do
    code =
      case reason do
        {code, _session, _generation} -> Atom.to_string(code)
        code -> Atom.to_string(code)
      end

    with {:ok, _ended} <- store.end_attempt(claim, run.id, lane.error(:session_unaddressable)),
         {:ok, _stopped} <- store.record_unaddressable_stop(claim, run.id, code),
         do: {:ok, :stopped}
  end

  # -- The session -------------------------------------------------------------------

  defp remote_session(%__MODULE__{lane: lane} = run_step, run) do
    {:ok, local} = lane.fleet_session().fetch_for_run(run)

    case local.coop_session_id do
      nil -> create_session(run_step, run, local)
      id -> located_session(run_step, call(run_step, :get_session, [id]), local)
    end
  end

  defp create_session(%__MODULE__{lane: lane, store: store} = run_step, run, local) do
    key = store.operation_key(run, :create)
    external_ref = lane.fleet_session().external_ref(run)
    source = lane.source(run)

    result =
      case call(run_step, :operation_by_key, [key]) do
        :not_found when run.status in [:rejected, :stale] ->
          # Ended before its session was asked for: nothing exists to stop.
          with {:ok, _run} <- store.record_uncreated_stop(run_step.claim, run.id),
               do: {:ok, :stopped}

        :not_found ->
          with :ok <- prepare_session(run_step, key, run.policy, external_ref, source),
               do: call(run_step, :create_session, [key, run.policy, external_ref, source])

        other ->
          other
      end

    case operation(run_step, result, "CreateRemoteSession", "session") do
      {:ok, %{"id" => id} = session} when is_binary(id) ->
        with {:ok, _bound} <- bind(run_step, run, id),
             do: located_session(run_step, {:ok, session}, reread(local))

      {:resource, id} ->
        with {:ok, _bound} <- bind(run_step, run, id),
             do: located_session(run_step, call(run_step, :get_session, [id]), reread(local))

      {:failed, operation} ->
        with {:ok, _run} <-
               store.record_failed_operation(run_step.claim, run.id, :create, operation),
             do: {:ok, :stopped}

      other ->
        other
    end
  end

  defp prepare_session(run_step, key, policy, external_ref, source) do
    %__MODULE__{lane: lane, claim: claim, settings: settings} = run_step

    with_lease_kept(lane, claim, settings, fn ->
      Coop.API.prepare_create_session(
        settings.api,
        settings.client,
        key,
        policy,
        external_ref,
        source
      )
    end)
  end

  defp reread(local), do: Repo.fetch!(Work.Session.Query.by_id(local.id))

  defp bind(%__MODULE__{lane: lane, store: store, claim: claim}, run, id),
    do: store.with_lease(claim, fn -> lane.fleet_session().bind(run, id) end)

  defp located_session(
         %__MODULE__{lane: lane},
         {:ok, %{"id" => id, "state" => state, "revision" => revision} = remote},
         local
       )
       when is_binary(id) and is_integer(revision) and revision > 0 do
    if local.coop_session_id == id and state in ~w(open exhausted closed discarded) and
         CoopFleet.JobAuthority.exact_receipt(local, remote) == :ok,
       do: {:ok, remote},
       else: {:error, lane.error(:session_authority_conflict)}
  end

  defp located_session(%__MODULE__{lane: lane}, {:ok, _remote}, _local),
    do: {:error, lane.error(:remote_protocol_error)}

  defp located_session(_run_step, other, _local), do: other

  # -- The turn ----------------------------------------------------------------------

  # A run that was ended (for an answer that failed a check, or a turn past
  # its time) only follows its turn to a stop; it never accepts or submits.
  defp turn_step(run_step, run, session) do
    case remote_turn(run_step, run, session) do
      {:ok, %{} = turn} ->
        run = run_step.store.current(run.id)

        if ended?(run),
          do: settle_stopped(run_step, run, session, turn),
          else: process_turn(run_step, run, session, turn)

      other ->
        other
    end
  end

  defp ended?(run), do: run.status in [:rejected, :stale]

  defp remote_turn(run_step, run, session) do
    result =
      case run.coop_turn_id do
        nil ->
          submit(run_step, run, session)

        turn_id ->
          with {:ok, turn} <- call(run_step, :get_turn, [session["id"], turn_id]),
               :ok <- exact_turn(run_step, turn, session["id"], turn_id),
               do: {:ok, turn}
      end

    with {:ok, %{} = turn} <- result,
         {:ok, _metered} <- observe(run_step, run, session, turn),
         do: {:ok, turn}
  end

  # The session revision is frozen before anything is sent. A submit Coop has
  # no record of was never sent, so an ended run stops on that proof instead
  # of sending it now.
  defp submit(%__MODULE__{store: store, claim: claim} = run_step, run, session) do
    key = store.operation_key(run, :submit)

    result =
      case call(run_step, :operation_by_key, [key]) do
        :not_found ->
          if ended?(run),
            do: unsubmitted(run_step, run, session),
            else: send_turn(run_step, run, session, key)

        other ->
          other
      end

    case operation(run_step, result, "SubmitTurn", "turn") do
      {:ok, %{"id" => id} = turn} when is_binary(id) ->
        bound_turn(run_step, run, session, turn)

      {:resource, id} ->
        with {:ok, turn} <- call(run_step, :get_turn, [session["id"], id]),
             do: bound_turn(run_step, run, session, turn)

      {:failed, operation} ->
        with {:ok, _run} <- store.record_failed_operation(claim, run.id, :submit, operation),
             do: {:ok, :stopped}

      other ->
        other
    end
  end

  defp send_turn(%__MODULE__{store: store, claim: claim} = run_step, run, session, key) do
    with {:ok, frozen} <-
           store.freeze_submit(claim, run.id, run.submit_revision || session["revision"]),
         {:ok, _metered} <- observe(run_step, frozen, session, %{"state" => "requested"}) do
      call(run_step, :submit_frozen_turn, [
        session["id"],
        key,
        frozen.submit_revision,
        submission(run_step, frozen),
        nil,
        []
      ])
    end
  end

  defp unsubmitted(%__MODULE__{store: store, claim: claim}, run, session) do
    with {:ok, _run} <- store.record_unsubmitted_stop(claim, run.id, session["id"]),
         do: {:ok, :stopped}
  end

  defp bound_turn(%__MODULE__{store: store, claim: claim} = run_step, run, session, turn) do
    with :ok <- exact_turn(run_step, turn, session["id"], nil),
         {:ok, _run} <- store.bind_turn(claim, run.id, session["id"], turn["id"]),
         do: {:ok, turn}
  end

  defp submission(%__MODULE__{lane: lane}, run),
    do: %{
      "contract_version" => lane.contract_version(),
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => run.output_schema,
      "prompt" => run.prompt
    }

  # An offered answer the store cannot keep, or one the lane's check refuses,
  # ends the run: reading the same turn again would only offer it again.
  defp process_turn(run_step, run, session, %{"state" => "awaiting_validation"} = turn) do
    # Coop records the selected target on the session, not on the turn.
    producer = turn |> Map.take(~w(id session_id)) |> Map.put("target", session["target"])

    case run_step.store.record_candidate(run_step.claim, run.id, turn, producer) do
      {:ok, saved} -> check_candidate(run_step, saved, session, turn)
      {:error, reason} -> refused(run_step, run, session, reason)
    end
  end

  defp process_turn(run_step, run, _session, %{"state" => "completed"} = turn),
    do: complete(run_step, run, turn)

  defp process_turn(%__MODULE__{lane: lane} = run_step, run, _session, %{"state" => state} = turn)
       when state in @terminal do
    reason =
      if state == "failed" and turn["error_code"] == "output_contract_failed",
        do: :output_contract_failed,
        else: lane.error(:provider_failed)

    with {:ok, _run} <- run_step.store.fail(run_step.claim, run.id, reason, turn),
         do: {:ok, :stopped}
  end

  defp process_turn(%__MODULE__{lane: lane} = run_step, run, session, %{"state" => state})
       when state in @waiting do
    if Repo.passed?(run.started_at, run_step.settings.execution_timeout_seconds),
      do: stop(run_step, run, session, lane.error(:execution_timeout)),
      else: {:ok, :waiting}
  end

  defp process_turn(%__MODULE__{lane: lane}, _run, _session, _turn),
    do: {:error, lane.error(:remote_protocol_error)}

  defp refused(%__MODULE__{lane: lane} = run_step, run, session, reason) do
    if lane.refused_candidate?(reason),
      do: stop(run_step, run, session, reason),
      else: {:error, reason}
  end

  defp check_candidate(%__MODULE__{lane: lane} = run_step, run, session, turn) do
    case lane.check(run_step.claim, run, run_step.context, run_step.settings) do
      :ok -> accept(run_step, run, session, turn)
      {:stop, reason} -> stop(run_step, run, session, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept(%__MODULE__{lane: lane} = run_step, run, session, turn) do
    sha256 = turn["candidate"]["sha256"]

    with {:ok, _accepted} <-
           call(run_step, :validate_frozen_candidate, [
             session["id"],
             turn["id"],
             lane.validate_key(run, sha256),
             run.candidate_attempt,
             sha256,
             :accept
           ]),
         {:ok, completed} <- call(run_step, :get_turn, [session["id"], turn["id"]]),
         {:ok, _metered} <- observe(run_step, run, session, completed) do
      if completed["state"] == "completed",
        do: complete(run_step, run, completed),
        else: {:ok, :waiting}
    end
  end

  # The turn is over and its answer accepted: the store applies it with the
  # turn's stop proof, which gives the lease back. An answer that cannot be
  # applied ends the attempt, and the finished turn is still its stop proof.
  defp complete(%__MODULE__{store: store, claim: claim}, run, turn) do
    result =
      with {:ok, _confirmed} <- store.confirm_candidate(claim, run.id, turn),
           do: store.apply_result(claim, run.id, turn)

    case result do
      {:ok, applied} ->
        {:ok, {:applied, applied}}

      {:error, reason} ->
        with {:ok, _ended} <- store.end_attempt(claim, run.id, reason),
             {:ok, _stopped} <- store.record_stop(claim, run.id, turn),
             do: {:ok, :stopped}
    end
  end

  # -- Stopping ----------------------------------------------------------------------

  # Ends the run for `reason` and stops what it started at the worker: a turn
  # never submitted stops on that proof, a finished one on its terminal state,
  # and a running one is cancelled and waited for.
  defp stop(%__MODULE__{store: store, claim: claim} = run_step, run, session, reason) do
    with {:ok, run} <- store.end_attempt(claim, run.id, reason) do
      if is_nil(run.remote_stopped_at),
        do: turn_step(run_step, run, session),
        else: {:ok, :stopped}
    end
  end

  defp settle_stopped(%__MODULE__{store: store, claim: claim} = run_step, run, session, turn) do
    if turn["state"] in @terminal do
      with {:ok, _run} <- store.record_stop(claim, run.id, turn), do: {:ok, :stopped}
    else
      key = store.operation_key(run, :cancel) <> ":r#{session["revision"]}"

      with {:ok, _cancelled} <-
             call(run_step, :cancel_turn, [session["id"], turn["id"], key, session["revision"]]),
           do: {:ok, :waiting}
    end
  end

  # -- Coop --------------------------------------------------------------------------

  # A create or submit answers with its resource, with an operation that may
  # still be running, or, looked up by key, with the operation itself.
  defp operation(run_step, {:ok, %{"operation" => operation}}, method, type),
    do: operation_state(run_step, operation, method, type)

  defp operation(run_step, {:ok, %{"method" => _method} = operation}, method, type),
    do: operation_state(run_step, operation, method, type)

  defp operation(%__MODULE__{lane: lane}, {:ok, resource}, _method, type) when is_map(resource) do
    case resource[type] do
      %{} = value -> {:ok, value}
      _other -> {:error, lane.error(:remote_protocol_error)}
    end
  end

  defp operation(_run_step, other, _method, _type), do: other

  defp operation_state(
         _run_step,
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

  defp operation_state(
         _run_step,
         %{"method" => method, "state" => "failed"} = operation,
         method,
         _
       ),
       do: {:failed, operation}

  defp operation_state(_run_step, %{"method" => method, "state" => state}, method, _type)
       when state in @pending,
       do: {:ok, :waiting}

  defp operation_state(%__MODULE__{lane: lane}, _operation, _method, _type),
    do: {:error, lane.error(:remote_unresolved)}

  defp exact_turn(%__MODULE__{lane: lane}, turn, session_id, expected) do
    if Coop.Documents.exact_turn?(turn, session_id, expected),
      do: :ok,
      else: {:error, lane.error(:remote_identity_conflict)}
  end

  # Every observed turn is metered under the lease.
  defp observe(%__MODULE__{lane: lane, store: store, claim: claim}, run, session, turn) do
    store.with_lease(claim, fn ->
      owner = store.fetch_and_lock_owned_in_transaction!(claim)
      {:ok, local} = lane.fleet_session().fetch_for_run(run)
      lane.observe_in_transaction(owner, run, local.id, turn, session, Repo.now!())
    end)
  end

  defp call(%__MODULE__{store: store, claim: claim, settings: settings}, operation, arguments) do
    with {:ok, _renewed} <- store.renew(claim, settings.lease_seconds) do
      apply(settings.api, operation, [settings.client | arguments])
    end
  end
end
