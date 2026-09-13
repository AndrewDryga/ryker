defmodule Ryker.Work.Executor.Remote do
  @moduledoc """
  The Coop call layer every executor step shares.

  Every call renews the lease when the heartbeat is due, and every mutation
  runs under the durable mutation fence keyed from the Work rows. Operation
  and resource reads prove the remote session and turn are exactly the ones
  the claim bound (identity, authority digest, state binding digest) before a
  step trusts them, and a lost response is reconciled through the operation
  its mutation was keyed with.
  """

  alias Ryker.Artifacts
  alias Ryker.State.KnowledgeSnapshot
  alias Ryker.Work.{Custody, Session, StateBinding}

  @git_commit_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
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

        {:error, _reason} = error ->
          error
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
  def create_key(session),
    do: "ryker:work:create:#{session.id}:g#{session.create_generation}"

  @doc false
  def turn_key(turn),
    do: "ryker:work:turn:#{turn.id}:g#{turn.submit_generation}:#{turn.submission_fingerprint}"

  @doc false
  def checkpoint_key(turn),
    do: "ryker:work:checkpoint:#{turn.id}:a#{turn.candidate_attempt}:#{turn.candidate_sha256}"

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

  def exact_remote_session_state(
        expected,
        %{
          "external_ref" => external_ref,
          "id" => id,
          "policy" => policy,
          "policy_digest" => policy_digest,
          "state" => state
        } = remote_session,
        allowed_states
      ) do
    remote_authority = {policy, policy_digest, external_ref}

    expected_authority =
      {expected.policy, expected.policy_digest, Session.coop_task_ref(expected)}

    with :ok <- exact_remote_session_identity(expected, id),
         :ok <- exact_remote_session_allowed_state(state, allowed_states),
         true <- remote_authority == expected_authority,
         true <- session_authority_digest_matches?(expected, remote_session),
         true <- is_nil(Map.get(remote_session, "responder_binding_digest")) do
      :ok
    else
      false -> {:error, {:coop_protocol_error, :session_authority}}
      {:error, _reason} = error -> error
    end
  end

  def exact_remote_session_state(_expected, _remote_session, _allowed_states),
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

  defp session_authority_digest_matches?(%{authority_digest: nil}, _remote_session), do: true

  defp session_authority_digest_matches?(expected, remote_session),
    do: remote_session["authority_digest"] == expected.authority_digest

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

      Map.get(remote_turn, "responder_binding_digest") != expected_binding_digest ->
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

    Process.put(settings.heartbeat_key, settings.monotonic_ms.())
    result
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
          Process.put(settings.heartbeat_key, now)
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  end

  @doc false
  def reference?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  @doc false
  def git_commit?(value),
    do: is_binary(value) and Regex.match?(@git_commit_regex, value)

  @doc false
  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
