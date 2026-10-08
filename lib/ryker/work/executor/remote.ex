defmodule Ryker.Work.Executor.Remote do
  @moduledoc """
  The Coop call layer every executor step shares.

  Every call renews the lease when the heartbeat is due, a step that can
  outlast the lease by itself runs beside renewals of its own
  (`with_lease_heartbeat/2`), and every mutation runs under the durable
  mutation fence keyed from the Work rows. Operation
  and resource reads prove the remote session and turn are exactly the ones
  the claim bound (identity, authority digest, state binding digest) before a
  step trusts them, and a lost response is reconciled through the operation
  its mutation was keyed with.
  """
  alias Ryker.Artifacts
  alias Ryker.CoopFleet.JobAuthority
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Reference
  alias Ryker.Work.{Custody, Session, StateBinding}

  @operation_waiting_states ~w(reserved running)
  @session_states ~w(open exhausted closed discarded)
  @terminal_turn_states ~w(cancelled completed failed interrupted budget_exhausted)
  @turn_waiting_states ~w(queued starting running)

  @doc false
  def terminal_turn_states, do: @terminal_turn_states

  @doc false
  def turn_waiting_states, do: @turn_waiting_states

  @doc false
  def operation_by_key(settings, key) do
    api_call(settings, fn -> settings.api.operation_by_key(settings.client, key) end)
  end

  @doc false
  def create_remote_session(settings, claim, key, task) do
    settings.api.create_session(
      settings.client,
      key,
      claim.session.policy,
      task,
      claim.session.repository_source
    )
  end

  @doc false
  def fence_remote_session(settings, claim, key) do
    settings.api.fence_create_session(
      settings.client,
      key,
      claim.session.policy,
      Session.coop_task_ref(claim.session),
      claim.session.repository_source
    )
  end

  @doc false
  def submit_frozen_turn(settings, claim, key, revision, artifacts) do
    with :ok <- KnowledgeSnapshot.expose_submission(claim) do
      settings.api.submit_frozen_turn(
        settings.client,
        claim.session.coop_session_id,
        key,
        revision,
        claim.turn.submission,
        state_binding_document(claim),
        artifacts
      )
    end
  end

  @doc false
  def fence_frozen_turn(settings, claim, key, revision, artifacts) do
    settings.api.fence_frozen_turn(
      settings.client,
      claim.session.coop_session_id,
      key,
      revision,
      claim.turn.submission,
      state_binding_document(claim),
      artifacts
    )
  end

  defp state_binding_document(%{state_binding: binding}), do: StateBinding.document(binding)
  defp state_binding_document(_claim), do: nil

  @doc false
  def input_artifacts(claim) do
    claim.turn.submission
    |> Map.get("input_artifact_refs", [])
    |> Artifacts.coop_inputs()
  end

  @doc false
  def fetch_bound_turn(claim, settings),
    do: fetch_turn(claim, claim.turn.coop_turn_id, settings)

  @doc false
  def fetch_turn(claim, turn_id, settings) do
    with {:ok, remote_turn} <-
           api_call(settings, fn ->
             settings.api.get_turn(settings.client, claim.session.coop_session_id, turn_id)
           end),
         :ok <-
           exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             turn_id,
             StateBinding.binding_digest(claim.turn)
           ) do
      {:ok, remote_turn}
    end
  end

  @doc false
  def operation_resource(
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

  def operation_resource(
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

  def operation_resource(
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

  def operation_resource(
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

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def operation_resource(
        %{"method" => method, "state" => state},
        _type,
        method,
        _key,
        _settings,
        0
      )
      when state in @operation_waiting_states,
      do: {:error, {:work_poll_window_elapsed, :operation}}

  def operation_resource(
        %{"method" => _actual},
        _type,
        _expected_method,
        _key,
        _settings,
        _left
      ),
      do: {:error, {:coop_protocol_error, :operation_method}}

  def operation_resource(_operation, _type, _method, _key, _settings, _left),
    do: {:error, {:coop_protocol_error, :operation_state}}

  @doc false
  def reconcile_after_transport(original_error, key, settings, continuation) do
    case operation_by_key(settings, key) do
      {:ok, operation} -> continuation.(operation)
      :not_found -> original_error
      {:error, _reason} -> original_error
    end
  end

  @doc false
  def ambiguous_mutation(phase, reason),
    do: {:error, {:coop_mutation_response_unresolved, phase, reason}}

  @doc false
  def revision(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  def revision(_resource), do: {:error, {:coop_protocol_error, :resource_revision}}

  @doc false
  def terminal_turn?(%{"state" => state}), do: state in @terminal_turn_states
  def terminal_turn?(_turn), do: false

  @doc false
  def exact_remote_session(expected, %{"state" => "open"} = remote_session),
    do: exact_remote_session_state(expected, remote_session, ["open"])

  def exact_remote_session(_expected, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  # Proves the remote session is the one the claim bound, in any state Coop
  # reports unless the caller narrows the states it can proceed from.
  @doc false
  def exact_remote_session_state(expected, remote_session, allowed_states \\ @session_states)

  def exact_remote_session_state(expected, remote, allowed_states) do
    with :ok <- JobAuthority.exact_receipt(expected, remote),
         do: exact_session_state(expected, remote, allowed_states)
  end

  def exact_cleanup_session(expected, remote, allowed_states \\ @session_states) do
    with :ok <- JobAuthority.exact_cleanup_receipt(expected, remote),
         do: exact_session_state(expected, remote, allowed_states)
  end

  defp exact_session_state(expected, %{"id" => id, "state" => state} = remote, allowed_states) do
    with :ok <- exact_remote_session_identity(expected, id),
         :ok <- exact_remote_session_allowed_state(state, allowed_states),
         true <- is_nil(Map.get(remote, "controller_tools_digest")) do
      :ok
    else
      false -> {:error, {:coop_protocol_error, :session_authority}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_session_state(_expected, _remote, _allowed_states),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp exact_remote_session_identity(expected, id) do
    if expected.coop_session_id in [nil, id] and reference?(id),
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_identity}}
  end

  defp exact_remote_session_allowed_state(state, allowed_states) do
    if state in allowed_states,
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_state}}
  end

  @doc false
  def exact_remote_turn(
        %{"id" => id, "session_id" => session_id} = remote_turn,
        expected_session_id,
        expected_turn_id,
        expected_binding_digest
      )
      when is_binary(id) and is_binary(session_id) do
    cond do
      session_id != expected_session_id ->
        {:error, {:coop_protocol_error, :turn_session_identity}}

      expected_turn_id != nil and id != expected_turn_id ->
        {:error, {:coop_protocol_error, :turn_identity}}

      not reference?(id) ->
        {:error, {:coop_protocol_error, :turn_identity}}

      Map.get(remote_turn, "controller_tools_digest") != expected_binding_digest ->
        {:error, {:coop_protocol_error, :turn_authority}}

      true ->
        :ok
    end
  end

  def exact_remote_turn(
        _remote_turn,
        _expected_session_id,
        _expected_turn_id,
        _expected_binding_digest
      ),
      do: {:error, {:coop_protocol_error, :turn_resource}}

  @doc false
  def api_call(settings, function) do
    with :ok <- maybe_renew(settings) do
      function.()
    end
  end

  @doc false
  def mutation_call(settings, kind, key, function),
    do: mutation_call(settings, kind, key, nil, function)

  @doc false
  def mutation_call(settings, kind, key, revision, function) do
    result =
      Custody.with_mutation_fence(
        settings.claim.episode.id,
        settings.claim.turn.turn_ref,
        settings.claim.lease_ref,
        %{
          kind: kind,
          lease_seconds: settings.lease_seconds,
          operation_key: key,
          operation_revision: revision
        },
        function
      )

    # The turn's last heartbeat, kept by the process running the turn.
    # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
    Process.put(settings.heartbeat_key, settings.monotonic_ms.())
    result
  end

  @doc """
  Runs `function`, a step that can outlast the lease by itself (preparing a
  repository's source can take minutes), while a process of its own renews
  the lease every heartbeat interval. The renewals end with the step however
  it ends, and a lease they could not keep is returned instead of the step's
  result.
  """
  def with_lease_heartbeat(settings, function) do
    heartbeat = Task.async(fn -> keep_lease(settings) end)

    {result, renewal} =
      try do
        result = function.()
        send(heartbeat.pid, :stop)
        {result, Task.await(heartbeat, :infinity)}
      after
        Task.shutdown(heartbeat, :brutal_kill)
      end

    case renewal do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp keep_lease(settings) do
    receive do
      :stop -> :ok
    after
      settings.heartbeat_interval_ms ->
        case renew_lease(settings) do
          {:error, reason} -> {:error, reason}
          _renewed_or_unreachable -> keep_lease(settings)
        end
    end
  end

  # A lease has three heartbeat intervals in it, so a renewal the database
  # could not take is tried again at the next one rather than given up.
  defp renew_lease(settings) do
    Custody.renew(
      settings.claim.episode.id,
      settings.claim.turn.turn_ref,
      settings.claim.lease_ref,
      settings.lease_seconds
    )
  rescue
    _unreachable in [DBConnection.ConnectionError, Postgrex.Error] -> :unreachable
  end

  @doc false
  def pause(settings) do
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
          # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
          Process.put(settings.heartbeat_key, now)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc false
  def reference?(value), do: Reference.valid?(value)
end
