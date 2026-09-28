defmodule Ryker.RepositoryKnowledge.Executor do
  @moduledoc """
  One resumable step of a knowledge run through Coop, after the self-analysis
  executor (`Ryker.Improvement.Executor`): every remote effect is keyed by
  the frozen run (`Ryker.RepositoryKnowledge.Custody.operation_key/2`), so a
  step repeated after a crash or a lost answer finds what it did before
  instead of doing it again.

  A step creates the run's session over the repository at the run's commit
  (or reads it), refuses to send anything to a session that is not a
  read-only copy of that repository alone, submits the frozen prompt once,
  and follows the turn. When the turn offers an answer, the host checks it
  against the contract and then against the repository itself: the tree at
  the run's commit and the files its commands cite
  (`Ryker.RepositoryKnowledge.Document.verify/3`). Only an answer that leaves
  something real is accepted; any other ends the run, and the next start is
  told why.

  Nothing is abandoned while its outcome is unknown: a create or a submit
  Coop has not finished is waited for, a turn past its time is cancelled and
  waited for, and only a day after the run's window (no Coop turn outlives
  one) does local proof alone close it. So a lost answer never buys a second
  model call.
  """

  alias Ryker.Coop.API
  alias Ryker.CoopFleet.JobAuthority
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge.{Custody, Document, FleetSession, Prompt}
  alias Ryker.Work.Session

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @pending ~w(reserved running)
  @waiting ~w(queued running pending requested starting)
  # Coop's MaxTurnTimeout: a session policy cannot allow a longer turn.
  @longest_turn_seconds 24 * 3_600

  @doc """
  Moves the run on by one step: `{:ok, {:applied, entry}}` once its checked
  document is ready to propose, `{:ok, :waiting}` while Coop is still
  working, `{:ok, :stopped}` once the run ended without one and has stop
  proof, or an error for a step to try again. `target` is the repository and
  its GitHub binding, or nil once the repository is gone: a run that can no
  longer be checked only stops.
  """
  def step(claim, run, target, settings) do
    run = Custody.current(run.id)

    cond do
      not is_nil(run.remote_stopped_at) ->
        {:ok, :stopped}

      expired?(run, @longest_turn_seconds + settings.execution_timeout_seconds) ->
        with {:ok, _run} <-
               Custody.record_expired_stop(
                 claim,
                 run.id,
                 @longest_turn_seconds + settings.execution_timeout_seconds
               ),
             do: {:ok, :stopped}

      true ->
        execute(claim, run, target, settings)
    end
  end

  defp execute(claim, run, target, settings) do
    case remote_session(claim, run, settings) do
      {:ok, %{} = session} ->
        session_step(claim, run, session, target, settings)

      {:error, reason} = error ->
        if unaddressable?(run, reason),
          do: give_up_session(claim, run, reason),
          else: error

      other ->
        other
    end
  end

  defp session_step(claim, run, session, target, settings) do
    cond do
      not isolated_session?(session) ->
        stop(claim, run, session, :repository_knowledge_session_not_isolated, target, settings)

      # The worker closed or used up the session before its turn was sent:
      # nothing can be sent to it, and a new start gets a new one.
      session["state"] != "open" and is_nil(run.coop_turn_id) and not ended?(run) ->
        stop(claim, run, session, :repository_knowledge_session_unaddressable, target, settings)

      true ->
        turn_step(claim, run, session, target, settings)
    end
  end

  # A session this run can no longer use: the worker holding it went away and
  # the fleet never replaces a session, or it is not this run's. The submit
  # revision is frozen before anything is sent, so without one no turn exists
  # to wait for, and giving up costs a start, never a model call.
  defp unaddressable?(run, reason),
    do: is_nil(run.submit_revision) and is_nil(run.coop_turn_id) and unaddressable?(reason)

  defp unaddressable?({:coop_session_replacement_required, _session, _generation}), do: true

  defp unaddressable?(reason),
    do:
      reason in [
        :repository_knowledge_session_authority_conflict,
        :repository_knowledge_session_identity_conflict
      ]

  defp give_up_session(claim, run, reason) do
    code =
      case reason do
        {code, _session, _generation} -> Atom.to_string(code)
        code -> Atom.to_string(code)
      end

    with {:ok, _ended} <-
           Custody.end_attempt(claim, run.id, :repository_knowledge_session_unaddressable),
         {:ok, _stopped} <- Custody.record_unaddressable_stop(claim, run.id, code),
         do: {:ok, :stopped}
  end

  # -- The session -------------------------------------------------------------------

  defp remote_session(claim, run, settings) do
    local = FleetSession.for_run(run)

    case local.coop_session_id do
      nil -> create_session(claim, run, local, settings)
      id -> located_session(call(claim, settings, :get_session, [id]), local)
    end
  end

  defp create_session(claim, run, local, settings) do
    key = Custody.operation_key(run, :create)
    source = FleetSession.source(run)

    result =
      case call(claim, settings, :operation_by_key, [key]) do
        :not_found when run.status in [:rejected, :stale] ->
          # Ended before its session was asked for: nothing exists to stop.
          with {:ok, _run} <- Custody.record_uncreated_stop(claim, run.id),
               do: {:ok, :stopped}

        :not_found ->
          prepare = fn ->
            API.prepare_create_session(
              settings.api,
              settings.client,
              key,
              run.policy,
              FleetSession.external_ref(run),
              source
            )
          end

          with :ok <- with_lease_kept(claim, settings, prepare) do
            call(claim, settings, :create_session, [
              key,
              run.policy,
              FleetSession.external_ref(run),
              source
            ])
          end

        other ->
          other
      end

    case operation(result, "CreateRemoteSession", "session") do
      {:ok, %{"id" => id} = session} when is_binary(id) ->
        with {:ok, _bound} <- bind(claim, run, id),
             do: located_session({:ok, session}, Repo.get!(Session, local.id))

      {:resource, id} ->
        with {:ok, _bound} <- bind(claim, run, id),
             do:
               located_session(
                 call(claim, settings, :get_session, [id]),
                 Repo.get!(Session, local.id)
               )

      {:failed, operation} ->
        with {:ok, _run} <- Custody.record_failed_operation(claim, run.id, :create, operation),
             do: {:ok, :stopped}

      other ->
        other
    end
  end

  defp bind(claim, run, id), do: Custody.with_lease(claim, fn -> FleetSession.bind(run, id) end)

  # Mirroring a large repository before its session can be created can take
  # minutes. The lease is renewed meanwhile, beside the preparation, so no
  # other worker takes the run over halfway (as Work's is, 2026-09-28).
  defp with_lease_kept(claim, settings, function) do
    heartbeat = Task.async(fn -> keep_lease(claim, settings) end)

    try do
      result = function.()
      send(heartbeat.pid, :stop)

      case Task.await(heartbeat, :infinity) do
        :ok -> result
        {:error, _lost} = lost -> lost
      end
    after
      Task.shutdown(heartbeat, :brutal_kill)
    end
  end

  defp keep_lease(claim, settings) do
    receive do
      :stop -> :ok
    after
      max(div(settings.lease_seconds * 1_000, 3), 100) ->
        case renew_lease(claim, settings) do
          :ok -> keep_lease(claim, settings)
          {:error, _lost} = lost -> lost
        end
    end
  end

  defp renew_lease(claim, settings) do
    case Custody.renew(claim, settings.lease_seconds) do
      {:ok, _renewed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A lease another worker holds now is not ours to renew.
    _lost -> {:error, :repository_knowledge_lease_lost}
  end

  defp located_session(
         {:ok, %{"id" => id, "state" => state, "revision" => revision} = remote},
         local
       )
       when is_binary(id) and is_integer(revision) and revision > 0 do
    if local.coop_session_id == id and state in ~w(open exhausted closed discarded) and
         JobAuthority.exact_receipt(local, remote) == :ok,
       do: {:ok, remote},
       else: {:error, :repository_knowledge_session_authority_conflict}
  end

  defp located_session({:ok, _remote}, _local),
    do: {:error, :repository_knowledge_remote_protocol_error}

  defp located_session(other, _local), do: other

  # The model reads the repository and nothing else: no tools of Ryker's, no
  # workspace task, no other repository, and nothing it could change.
  defp isolated_session?(session),
    do:
      is_nil(session["controller_tools_digest"]) and is_nil(session["workspace_task"]) and
        session["repository_read_only"] == true and session["project_env"] == false and
        session["project_mcp"] == false and Map.get(session, "companions", []) == []

  # -- The turn ----------------------------------------------------------------------

  # A run that was ended (for an answer that failed a check, or a turn past
  # its time) only follows its turn to a stop; it never accepts or submits.
  defp turn_step(claim, run, session, target, settings) do
    case remote_turn(claim, run, session, settings) do
      {:ok, %{} = turn} ->
        run = Custody.current(run.id)

        if ended?(run),
          do: settle_stopped(claim, run, session, turn, settings),
          else: process_turn(claim, run, session, turn, target, settings)

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
    key = Custody.operation_key(run, :submit)

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
        with {:ok, _run} <- Custody.record_failed_operation(claim, run.id, :submit, operation),
             do: {:ok, :stopped}

      other ->
        other
    end
  end

  defp send_turn(claim, run, session, settings, key) do
    with {:ok, frozen} <-
           Custody.freeze_submit(claim, run.id, run.submit_revision || session["revision"]),
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
    with {:ok, _run} <- Custody.record_unsubmitted_stop(claim, run.id, session["id"]),
         do: {:ok, :stopped}
  end

  defp bound_turn(claim, run, session, turn) do
    with :ok <- exact_turn(turn, session["id"], nil),
         {:ok, _run} <- Custody.bind_turn(claim, run.id, session["id"], turn["id"]),
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

  defp process_turn(
         claim,
         run,
         session,
         %{"state" => "awaiting_validation"} = turn,
         target,
         settings
       ) do
    # Coop records the selected target on the session, not on the turn.
    producer = turn |> Map.take(~w(id session_id)) |> Map.put("target", session["target"])

    case Custody.record_candidate(claim, run.id, turn, producer) do
      {:ok, saved} ->
        check_candidate(claim, saved, session, turn, target, settings)

      # An answer the run cannot keep (larger than it holds, or not what its
      # digest names) is refused the same way every time it is asked for:
      # the attempt ends and its turn is cancelled, so the next start comes.
      {:error, reason}
      when reason in [:invalid_repository_knowledge, :invalid_repository_knowledge_candidate] ->
        stop(claim, run, session, reason, target, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp process_turn(claim, run, _session, %{"state" => "completed"} = turn, _target, _settings),
    do: complete(claim, run, turn)

  defp process_turn(claim, run, _session, %{"state" => state} = turn, _target, _settings)
       when state in @terminal do
    reason =
      if state == "failed" and turn["error_code"] == "output_contract_failed",
        do: :output_contract_failed,
        else: :repository_knowledge_provider_failed

    with {:ok, _run} <- Custody.fail(claim, run.id, reason, turn), do: {:ok, :stopped}
  end

  defp process_turn(claim, run, session, %{"state" => state}, target, settings)
       when state in @waiting do
    if expired?(run, settings.execution_timeout_seconds),
      do: stop(claim, run, session, :repository_knowledge_execution_timeout, target, settings),
      else: {:ok, :waiting}
  end

  defp process_turn(_claim, _run, _session, _turn, _target, _settings),
    do: {:error, :repository_knowledge_remote_protocol_error}

  defp check_candidate(claim, run, session, turn, target, settings) do
    case checked_document(claim, run, target, settings) do
      {:ok, _document} -> accept(claim, run, session, turn, settings)
      {:error, reason} when is_atom(reason) -> stop(claim, run, session, reason, target, settings)
      {:retry, reason} -> {:error, reason}
    end
  end

  # The answer, checked against the contract and then against the repository
  # at the run's commit, as the document the host writes from it. A document
  # written before (the step is repeated after a crash) is not checked again.
  # GitHub not answering is not the model's fault: the step waits.
  defp checked_document(_claim, %{document: document}, _target, _settings)
       when is_binary(document),
       do: {:ok, document}

  defp checked_document(_claim, _run, nil, _settings), do: {:error, :repository_knowledge_removed}

  defp checked_document(claim, run, {repository, binding}, settings) do
    with {:ok, answer} <- Prompt.parse(run.result),
         {:ok, _renewed} <- Custody.renew(claim, settings.lease_seconds),
         {:ok, tree} <- remote_tree(settings, binding, repository, run.source_commit),
         {:ok, sources} <-
           sources(
             settings,
             binding,
             repository,
             run.source_commit,
             Document.cited_sources(answer, tree)
           ),
         {:ok, kept, dropped} <- Document.verify(answer, tree, sources),
         {:ok, document} <- Document.render(kept, run.source_commit, Date.utc_today()) do
      with {:ok, _run} <- Custody.record_document(claim, run.id, document, dropped),
           do: {:ok, document}
    else
      {:error, reason}
      when reason in [:invalid_repository_knowledge, :repository_knowledge_unusable] ->
        {:error, reason}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp remote_tree(settings, binding, repository, commit) do
    with {:ok, entries} <- settings.remote.tree(binding, repository, commit),
         do: {:ok, Document.tree(entries)}
  end

  # A cited file Ryker cannot read (too large, not text) cites nothing: its
  # commands are dropped, not the answer.
  defp sources(settings, binding, repository, commit, paths) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, sources} ->
      case settings.remote.read(binding, repository, path, commit) do
        {:ok, text} when is_binary(text) -> {:cont, {:ok, Map.put(sources, path, text)}}
        {:ok, :not_found} -> {:cont, {:ok, sources}}
        {:error, :source_unavailable} -> {:cont, {:ok, sources}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp accept(claim, run, session, turn, settings) do
    key =
      "ryker:knowledge:validate:#{run.id}:a#{run.candidate_attempt}:#{turn["candidate"]["sha256"]}"

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

  # The turn is over and its answer accepted: the document becomes the one to
  # propose, with the turn's stop proof. One that cannot be applied ends the
  # attempt, and the finished turn is still its stop proof.
  defp complete(claim, run, turn) do
    result =
      with {:ok, _confirmed} <- Custody.confirm_candidate(claim, run.id, turn),
           do: Custody.apply_result(claim, run.id, turn)

    case result do
      {:ok, entry} ->
        {:ok, {:applied, entry}}

      {:error, reason} ->
        with {:ok, _ended} <- Custody.end_attempt(claim, run.id, reason),
             {:ok, _stopped} <- Custody.record_stop(claim, run.id, turn),
             do: {:ok, :stopped}
    end
  end

  # -- Stopping ----------------------------------------------------------------------

  @doc """
  Ends the run for `reason` and stops what it started at the worker: a turn
  never submitted stops on that proof, a finished one on its terminal state,
  and a running one is cancelled and waited for.
  """
  def stop(claim, run, session, reason, target, settings) do
    with {:ok, run} <- Custody.end_attempt(claim, run.id, reason) do
      if is_nil(run.remote_stopped_at),
        do: turn_step(claim, run, session, target, settings),
        else: {:ok, :stopped}
    end
  end

  defp settle_stopped(claim, run, session, turn, settings) do
    if turn["state"] in @terminal do
      with {:ok, _run} <- Custody.record_stop(claim, run.id, turn), do: {:ok, :stopped}
    else
      key = Custody.operation_key(run, :cancel) <> ":r#{session["revision"]}"

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
      _other -> {:error, :repository_knowledge_remote_protocol_error}
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

  defp operation_state(_operation, _method, _type),
    do: {:error, :repository_knowledge_remote_unresolved}

  defp exact_turn(%{"id" => id, "session_id" => session_id}, session_id, expected)
       when is_binary(id) and byte_size(id) in 1..1024 and (is_nil(expected) or expected == id),
       do: :ok

  defp exact_turn(_turn, _session_id, _expected),
    do: {:error, :repository_knowledge_remote_identity_conflict}

  # Every observed turn is metered under the lease, as self-analysis's are.
  defp observe(claim, run, session, turn) do
    Custody.with_lease(claim, fn ->
      entry = Custody.lock_owned_in_transaction!(claim)
      local = FleetSession.for_run(run)

      Ryker.Accounting.observe_knowledge_in_transaction(
        entry,
        run,
        local.id,
        turn,
        session,
        DateTime.utc_now()
      )
    end)
  end

  defp call(claim, settings, operation, arguments) do
    with {:ok, _renewed} <- Custody.renew(claim, settings.lease_seconds) do
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
