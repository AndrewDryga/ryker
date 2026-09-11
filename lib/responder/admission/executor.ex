defmodule Responder.Admission.Executor do
  alias Responder.Work.Activity

  @moduledoc """
  Runs one durable ingress input through Coop's admission model turn.

  Coop enforces the JSON Schema and repairs malformed output in the native
  session. This module then checks the frozen host-owned candidate set. A
  semantic rejection goes back to the same Coop turn; a valid decision is
  committed through `Responder.Admission`.
  """

  alias Responder.Admission
  alias Responder.Admission.{Attempts, Context, Decision, Prompt}
  alias Responder.CanonicalJSON
  alias Responder.Ingress.{Inbox, Input, WorkProfile}
  alias Responder.State.{Knowledge, Observations}

  @retryable_terminal_turn_states ~w(failed)
  @stopped_turn_states ~w(cancelled interrupted budget_exhausted)
  @waiting_turn_states ~w(queued starting running)
  @operation_waiting_states ~w(reserved running)

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(input_ref, options) do
    with {:ok, settings} <- settings(options),
         {:ok, settings} <- start_deadline(settings),
         :ok <- renew_lease(settings),
         {:ok, entry} <- Inbox.fetch(input_ref),
         {:ok, entry, context} <- execution_context(input_ref, entry, settings),
         {:ok, attempt} <- Attempts.prepare(entry, settings),
         settings <-
           Map.merge(settings, %{policy: attempt.policy, policy_digest: attempt.policy_digest}),
         :ok <- Attempts.observe(entry, "execution_requested", %{}, settings),
         :ok <- prepare_execution_session(entry, settings),
         {:ok, session} <- ensure_session(entry, settings),
         :ok <- bind_execution_session(entry, session, settings),
         settings <- Map.put(settings, :execution_target, session["target"]),
         :ok <-
           Attempts.observe(
             entry,
             "execution_requested",
             %{session_ref: session["id"], execution_target: session["target"]},
             settings
           ) do
      run_context(entry, session, context, settings)
    else
      :error -> {:error, {:admission_execution_failed, :input_not_found}}
      {:error, _reason} = error -> error
    end
  end

  defp run_context(entry, session, context, settings) do
    with :ok <- reauthorize_context(entry, context),
         {:ok, turn} <- ensure_turn(entry, session, context, settings),
         {:ok, decision, candidate_sha256} <- await_decision(turn, context, entry, settings),
         {:ok, work_policy} <- work_policy(entry, decision, settings),
         :ok <- close_session(session, entry, settings),
         :ok <- reauthorize_context(entry, context),
         {:ok, result} <-
           Admission.commit(context, decision, decision_ref(turn, candidate_sha256),
             lease_ref: settings.lease_ref,
             work_policy: work_policy
           ) do
      {:ok,
       %{
         cleanup: :closed,
         decision: decision,
         result: result,
         session_id: session["id"],
         turn_id: turn["id"]
       }}
    else
      {:error, {:admission_rejected, :context_stale} = reason} ->
        close_then(session, entry, settings, generation_spent(reason))

      {:error, :episode_cancelled = reason} ->
        close_then(session, entry, settings, generation_spent(reason))

      {:error, {:admission_generation_spent, _reason}} = error ->
        close_then(session, entry, settings, error)

      {:error, {:admission_execution_stopped, reason}} ->
        close_then(session, entry, settings, {:error, {:admission_execution_blocked, reason}})

      {:error, {:coop_protocol_error, :validated_candidate_mismatch} = reason} ->
        block_after_close(session, entry, settings, reason)

      {:error, _reason} = error ->
        error
    end
  end

  defp reauthorize_context(entry, context) do
    with :ok <- Observations.reauthorize(entry, entry.repository_ref, context.observations),
         do: Knowledge.reauthorize(entry, entry.repository_ref, context.knowledge)
  end

  defp work_policy(_entry, %Decision{work_class: nil}, _settings), do: {:ok, nil}

  defp work_policy(
         %{work_profile: profile},
         %Decision{work_class: work_class},
         _settings
       )
       when is_map(profile) do
    case WorkProfile.restore(profile) do
      {:ok, restored} -> WorkProfile.policy_for(restored, work_class)
      {:error, _reason} = error -> error
    end
  end

  defp work_policy(
         %{work_policy: policy, work_policy_digest: digest, repository_ref: repository_ref},
         %Decision{},
         _settings
       )
       when is_binary(policy) and is_binary(digest) do
    {:ok, %{digest: digest, name: policy, repository_ref: repository_ref}}
  end

  defp work_policy(_entry, %Decision{}, settings) do
    {:ok, %{digest: settings.policy_digest, name: settings.policy, repository_ref: nil}}
  end

  defp admission_context(input_ref, settings) do
    Admission.context(input_ref,
      candidate_limit: settings.candidate_limit,
      continuation_window: settings.continuation_window,
      history_window: settings.history_window,
      lease_ref: settings.lease_ref,
      now: settings.now.()
    )
  end

  defp execution_context(input_ref, %{admission_context: nil}, settings) do
    with {:ok, context} <- admission_context(input_ref, settings),
         snapshot <- Context.snapshot(context),
         {:ok, entry} <- Inbox.bind_context(input_ref, settings.lease_ref, snapshot) do
      {:ok, entry, %{context | input_entry: entry}}
    end
  end

  defp execution_context(_input_ref, entry, settings) do
    with {:ok, context} <- Admission.restore_context(entry, settings.lease_ref) do
      {:ok, entry, context}
    end
  end

  defp ensure_session(entry, settings) do
    key = create_key(entry)

    with :ok <- renew_lease(settings) do
      settings.api.operation_by_key(settings.client, key)
    end
    |> case do
      :not_found ->
        create_session(entry, key, settings)

      {:ok, operation} ->
        session_from_operation(entry, operation, key, settings, settings.max_polls)

      {:error, _reason} = error ->
        error
    end
  end

  defp create_session(entry, key, settings) do
    task = session_external_ref(entry)

    with :ok <- renew_lease(settings) do
      settings.api.create_session(settings.client, key, settings.policy, task, nil)
    end
    |> case do
      {:ok, %{"session" => session}} when is_map(session) ->
        validate_session(entry, session, settings)

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        session_from_operation(entry, operation, key, settings, settings.max_polls)

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :create_session_response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp session_from_operation(entry, operation, key, settings, polls_left) do
    with {:ok, resource_id} <-
           operation_resource(
             operation,
             "session",
             "CreateRemoteSession",
             key,
             settings,
             polls_left
           ) do
      with {:ok, session} <- settings.api.get_session(settings.client, resource_id) do
        validate_session_state(
          entry,
          session,
          settings,
          resource_id,
          ~w(open closed discarded)
        )
      end
    end
  end

  defp ensure_turn(entry, session, context, settings) do
    key = turn_key(entry, context)

    with :ok <- renew_lease(settings) do
      settings.api.operation_by_key(settings.client, key)
    end
    |> case do
      :not_found -> submit_turn(entry, session, context, key, settings)
      {:ok, operation} -> turn_from_operation(operation, session["id"], key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp submit_turn(entry, session, context, key, settings) do
    prompt = context |> Prompt.build() |> CanonicalJSON.encode!()

    schema =
      Decision.json_schema(
        Input.allowed_actions(context.input),
        Input.reaction_names(context.input)
      )

    with :ok <- renew_lease(settings),
         {:ok, artifact} <-
           Attempts.freeze(entry, %{"prompt" => prompt, "output_schema" => schema}, settings),
         {:ok, current_session} <- settings.api.get_session(settings.client, session["id"]),
         {:ok, current_session} <-
           validate_session(entry, current_session, settings, session["id"]),
         {:ok, revision} <- session_revision(current_session),
         :ok <- reauthorize_context(entry, context),
         {:ok, response} <-
           settings.api.submit_turn(
             settings.client,
             session["id"],
             key,
             revision,
             artifact.submission["prompt"],
             artifact.submission["output_schema"]
           ) do
      case response do
        %{"turn" => turn} when is_map(turn) ->
          validate_turn(turn, session["id"])

        %{"operation" => operation} when is_map(operation) ->
          turn_from_operation(operation, session["id"], key, settings)

        _response ->
          {:error, {:coop_protocol_error, :submit_turn_response}}
      end
    end
  end

  defp turn_from_operation(operation, session_id, key, settings) do
    with {:ok, resource_id} <-
           operation_resource(
             operation,
             "turn",
             "SubmitTurn",
             key,
             settings,
             settings.max_polls
           ),
         {:ok, turn} <- settings.api.get_turn(settings.client, session_id, resource_id) do
      validate_turn(turn, session_id, resource_id)
    end
  end

  defp operation_resource(
         %{"method" => method, "state" => "succeeded"} = operation,
         type,
         method,
         _key,
         _settings,
         _left
       ) do
    if operation["resource_type"] == type and valid_ref?(operation["resource_id"]),
      do: {:ok, operation["resource_id"]},
      else: {:error, {:coop_protocol_error, :operation_resource}}
  end

  defp operation_resource(
         %{"method" => method, "state" => "failed"} = operation,
         _type,
         method,
         _key,
         _settings,
         _left
       ) do
    generation_spent(
      {:coop_operation_failed, operation["error_code"] || "failed",
       operation["error_detail"] || "Coop operation failed"}
    )
  end

  defp operation_resource(
         %{"method" => method, "state" => "uncertain"} = operation,
         _type,
         method,
         _key,
         _settings,
         _left
       ) do
    {:error,
     {:admission_execution_blocked,
      {:coop_operation_uncertain, operation["error_code"] || "uncertain",
       operation["error_detail"] || "Coop operation outcome is uncertain"}}}
  end

  defp operation_resource(
         %{"method" => method, "state" => state},
         type,
         method,
         key,
         settings,
         left
       )
       when state in @operation_waiting_states and left > 0 do
    with :ok <- renew_lease(settings),
         :ok <- poll_wait(settings, :operation) do
      case settings.api.operation_by_key(settings.client, key) do
        {:ok, operation} ->
          operation_resource(operation, type, method, key, settings, left - 1)

        :not_found ->
          {:error, {:coop_protocol_error, :operation_disappeared}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp operation_resource(
         %{"method" => method, "state" => state},
         _type,
         method,
         _key,
         _settings,
         0
       )
       when state in @operation_waiting_states,
       do: {:error, {:coop_timeout, :operation}}

  defp operation_resource(
         %{"method" => _actual},
         _type,
         _expected,
         _key,
         _settings,
         _left
       ),
       do: {:error, {:coop_protocol_error, :operation_method}}

  defp operation_resource(_operation, _type, _method, _key, _settings, _left),
    do: {:error, {:coop_protocol_error, :operation_state}}

  defp await_decision(turn, context, entry, settings) do
    await_decision(turn, context, entry, settings, settings.max_polls)
  end

  defp await_decision(turn, context, entry, settings, left) do
    with :ok <- Attempts.observe_turn(entry, turn, settings) do
      # Telemetry has separate retry custody and must never reject a valid routing decision.
      _ = Activity.sync_admission(entry, turn["session_id"], settings)
      observed_decision(turn, context, entry, settings, left)
    end
  end

  defp observed_decision(
         %{"state" => "awaiting_validation", "candidate" => candidate} = turn,
         context,
         entry,
         settings,
         left
       )
       when is_map(candidate) do
    candidate_decision(turn, candidate, context, entry, settings, left)
  end

  defp observed_decision(
         %{
           "state" => "completed",
           "assistant_message" => message,
           "validation_attempt" => validation_attempt,
           "validation_candidate_sha256" => candidate_sha256,
           "validation_receipt" => validation_receipt
         },
         context,
         _entry,
         _settings,
         _left
       )
       when is_binary(message) and is_integer(validation_attempt) and validation_attempt > 0 and
              is_binary(candidate_sha256) and
              is_binary(validation_receipt) do
    if valid_ref?(validation_receipt) and sha256(message) == candidate_sha256 do
      case parse_and_validate(message, context) do
        {:ok, decision} -> {:ok, decision, candidate_sha256}
        {:error, reason} -> generation_spent(reason)
      end
    else
      generation_spent({:coop_protocol_error, :validation_receipt})
    end
  end

  defp observed_decision(
         %{"state" => "completed"},
         _context,
         _entry,
         _settings,
         _left
       ),
       do: generation_spent({:coop_protocol_error, :validation_receipt})

  defp observed_decision(%{"state" => state} = turn, _context, _entry, _settings, _left)
       when state in @retryable_terminal_turn_states do
    generation_spent({:coop_turn_failed, state, turn["error_code"], turn["error_detail"]})
  end

  defp observed_decision(%{"state" => state} = turn, _context, _entry, _settings, _left)
       when state in @stopped_turn_states do
    {:error,
     {:admission_execution_stopped,
      {:coop_turn_stopped, state, turn["error_code"], turn["error_detail"]}}}
  end

  defp observed_decision(%{"state" => state} = turn, context, entry, settings, left)
       when state in @waiting_turn_states and left > 0 do
    with :ok <- renew_lease(settings) do
      poll_decision(turn, context, entry, settings, left)
    end
  end

  defp observed_decision(%{"state" => state}, _context, _entry, _settings, 0)
       when state in @waiting_turn_states,
       do: {:error, {:coop_timeout, :turn}}

  defp observed_decision(_turn, _context, _entry, _settings, _left),
    do: {:error, {:coop_protocol_error, :turn_state}}

  defp poll_decision(turn, context, entry, settings, left) do
    with :ok <- poll_wait(settings, :turn),
         {:ok, current} <-
           settings.api.get_turn(settings.client, turn["session_id"], turn["id"]),
         {:ok, current} <- validate_turn(current, turn["session_id"], turn["id"]) do
      await_decision(current, context, entry, settings, left - 1)
    end
  end

  defp candidate_decision(turn, candidate, context, entry, settings, left) do
    with {:ok, message, candidate_sha256, candidate_attempt} <- candidate_fields(candidate),
         :ok <- Attempts.observe(entry, "host_validation", %{}, settings) do
      case parse_and_validate(message, context) do
        {:ok, decision} ->
          accept_candidate(
            turn,
            decision,
            candidate_sha256,
            candidate_attempt,
            context,
            entry,
            settings,
            left
          )

        {:error, reason} ->
          reject_candidate(
            turn,
            candidate_sha256,
            candidate_attempt,
            reason,
            context,
            entry,
            settings,
            left
          )
      end
    end
  end

  defp accept_candidate(
         turn,
         decision,
         candidate_sha256,
         candidate_attempt,
         context,
         entry,
         settings,
         left
       ) do
    key = validation_key(entry, candidate_attempt, candidate_sha256, "accept")

    with :ok <- renew_lease(settings) do
      settings.api.validate_candidate(
        settings.client,
        turn["session_id"],
        turn["id"],
        key,
        candidate_sha256,
        :accept
      )
    end
    |> case do
      {:ok, %{"turn" => completed}} ->
        with {:ok, completed} <-
               validate_turn(completed, turn["session_id"], turn["id"]),
             :ok <- exact_validation_attempt(completed, candidate_attempt),
             {:ok, completed_decision, completed_sha256} <-
               await_decision(completed, context, entry, settings, left),
             :ok <-
               validated_candidate_matches(
                 decision,
                 candidate_sha256,
                 completed_decision,
                 completed_sha256
               ) do
          {:ok, completed_decision, completed_sha256}
        end

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :validation_response}}

      {:error, _reason} = error ->
        validation_error(error)
    end
  end

  defp reject_candidate(
         turn,
         candidate_sha256,
         candidate_attempt,
         reason,
         context,
         entry,
         settings,
         left
       ) do
    key = validation_key(entry, candidate_attempt, candidate_sha256, "reject")
    violations = [violation(reason)]

    with :ok <- renew_lease(settings) do
      settings.api.validate_candidate(
        settings.client,
        turn["session_id"],
        turn["id"],
        key,
        candidate_sha256,
        {:reject, violations}
      )
    end
    |> case do
      {:ok, %{"turn" => current}} ->
        with {:ok, current} <- validate_turn(current, turn["session_id"], turn["id"]) do
          await_decision(current, context, entry, settings, left)
        end

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :validation_response}}

      {:error, _reason} = error ->
        validation_error(error)
    end
  end

  defp validated_candidate_matches(
         submitted_decision,
         submitted_sha256,
         completed_decision,
         completed_sha256
       ) do
    if submitted_sha256 == completed_sha256 and
         Decision.fingerprint(submitted_decision) == Decision.fingerprint(completed_decision),
       do: :ok,
       else: {:error, {:coop_protocol_error, :validated_candidate_mismatch}}
  end

  defp parse_and_validate(message, context) do
    with {:ok, document} <- decode_candidate(message),
         {:ok, decision} <- Decision.parse(document),
         {:ok, _selection} <- Admission.validate(context, decision) do
      {:ok, decision}
    end
  end

  defp decode_candidate(message) do
    case Jason.decode(message) do
      {:ok, document} when is_map(document) -> {:ok, document}
      _other -> {:error, {:invalid_candidate, :json_object}}
    end
  end

  defp candidate_fields(%{
         "attempt" => candidate_attempt,
         "message" => message,
         "sha256" => candidate_sha256
       })
       when is_integer(candidate_attempt) and candidate_attempt > 0 and is_binary(message) and
              is_binary(candidate_sha256) do
    if sha256(message) == candidate_sha256,
      do: {:ok, message, candidate_sha256, candidate_attempt},
      else: {:error, {:coop_protocol_error, :candidate_digest}}
  end

  defp candidate_fields(_candidate), do: {:error, {:coop_protocol_error, :candidate}}

  defp violation({:admission_rejected, :action_not_allowed, details}) do
    "The action is unavailable for this source. Choose one of the supplied allowed_actions. Submitted: #{inspect(details[:submitted])}."
  end

  defp violation({:admission_rejected, :unknown_candidate}) do
    "episode_ref is not one of the opaque candidate references supplied in this prompt."
  end

  defp violation({:admission_rejected, :relation_not_allowed, details}) do
    "The selected relation is unavailable for that candidate. Allowed: #{inspect(details[:allowed])}; submitted: #{inspect(details[:submitted])}."
  end

  defp violation({:admission_rejected, :reaction_not_allowed, details}) do
    "The reaction is unavailable for this source. Allowed emoji names: #{inspect(details[:allowed])}; submitted: #{inspect(details[:submitted])}."
  end

  defp violation({:invalid_decision, field}) do
    "The decision field #{field} does not satisfy the attached response schema."
  end

  defp violation({:invalid_candidate, :json_object}) do
    "Return exactly one JSON object matching the attached response schema."
  end

  defp violation(reason), do: "The host rejected this decision: #{inspect(reason)}"

  defp close_session(session, entry, settings) do
    with :ok <- renew_lease(settings),
         {:ok, current} <- settings.api.get_session(settings.client, session["id"]),
         {:ok, current} <-
           validate_session_state(
             entry,
             current,
             settings,
             session["id"],
             ~w(open exhausted closed discarded)
           ),
         :ok <- close_current_session(current, entry, settings) do
      _ = Activity.close_admission(entry, session["id"])
      settle_execution_session(entry, session["id"], settings)
    end
  end

  defp close_current_session(%{"state" => state}, _entry, _settings)
       when state in ["closed", "discarded"],
       do: :ok

  defp close_current_session(%{"id" => session_id, "revision" => revision}, entry, settings)
       when is_binary(session_id) and is_integer(revision) and revision > 0 do
    case settings.api.close_session(
           settings.client,
           session_id,
           close_key(entry),
           revision
         ) do
      {:ok, %{"session" => closed}} when is_map(closed) ->
        case validate_session_state(
               entry,
               closed,
               settings,
               session_id,
               ~w(closed discarded)
             ) do
          {:ok, _closed} -> :ok
          {:error, _reason} = error -> error
        end

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :close_session_response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp close_current_session(_session, _entry, _settings),
    do: {:error, {:coop_protocol_error, :session_state}}

  defp settings(options) when is_list(options) do
    allowed = [
      :api,
      :bind_execution_session,
      :candidate_limit,
      :client,
      :continuation_window,
      :history_window,
      :lease_ref,
      :maximum_elapsed_ms,
      :max_polls,
      :monotonic_ms,
      :now,
      :policy,
      :policy_digest,
      :poll_interval_ms,
      :prepare_execution_session,
      :renew_lease,
      :settle_execution_session,
      :sleep
    ]

    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      validate_settings(%{
        api: Keyword.get(options, :api, Responder.Coop.Client),
        bind_execution_session:
          Keyword.get(options, :bind_execution_session, fn _entry, _session_id -> :ok end),
        candidate_limit: Keyword.get(options, :candidate_limit, 20),
        client: Keyword.fetch!(options, :client),
        continuation_window: Keyword.get(options, :continuation_window, 30 * 60),
        history_window: Keyword.get(options, :history_window, 30 * 24 * 60 * 60),
        lease_ref: Keyword.fetch!(options, :lease_ref),
        maximum_elapsed_ms: Keyword.get(options, :maximum_elapsed_ms, 30_000),
        max_polls: Keyword.get(options, :max_polls, 600),
        monotonic_ms:
          Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        policy: Keyword.fetch!(options, :policy),
        policy_digest: Keyword.fetch!(options, :policy_digest),
        poll_interval_ms: Keyword.get(options, :poll_interval_ms, 250),
        prepare_execution_session:
          Keyword.get(options, :prepare_execution_session, fn _entry, _policy -> :ok end),
        renew_lease: Keyword.fetch!(options, :renew_lease),
        settle_execution_session:
          Keyword.get(options, :settle_execution_session, fn _entry, _session_id -> :ok end),
        sleep: Keyword.get(options, :sleep, &Process.sleep/1)
      })
    else
      {:error, {:invalid_admission_executor, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_admission_executor, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_admission_executor, :options}}

  defp validate_settings(settings) do
    with :ok <- executor_value(is_atom(settings.api), :api),
         :ok <-
           executor_value(
             is_function(settings.bind_execution_session, 2),
             :bind_execution_session
           ),
         :ok <- executor_value(is_function(settings.now, 0), :now),
         :ok <- executor_value(is_function(settings.renew_lease, 0), :renew_lease),
         :ok <- executor_value(is_function(settings.sleep, 1), :sleep),
         :ok <- executor_value(valid_ref?(settings.policy), :policy),
         :ok <- executor_value(valid_digest?(settings.policy_digest), :policy_digest),
         :ok <-
           executor_value(
             is_function(settings.prepare_execution_session, 2),
             :prepare_execution_session
           ),
         :ok <- executor_value(valid_ref?(settings.lease_ref), :lease_ref),
         :ok <- executor_value(positive?(settings.candidate_limit), :candidate_limit),
         :ok <- executor_value(positive?(settings.continuation_window), :continuation_window),
         :ok <- valid_history_window(settings),
         :ok <- executor_value(positive?(settings.maximum_elapsed_ms), :maximum_elapsed_ms),
         :ok <- executor_value(positive?(settings.max_polls), :max_polls),
         :ok <- executor_value(is_function(settings.monotonic_ms, 0), :monotonic_ms),
         :ok <-
           executor_value(
             is_function(settings.settle_execution_session, 2),
             :settle_execution_session
           ),
         :ok <- valid_poll_interval(settings.poll_interval_ms) do
      {:ok, settings}
    end
  end

  defp valid_history_window(settings) do
    executor_value(
      positive?(settings.history_window) and
        settings.history_window >= settings.continuation_window,
      :history_window
    )
  end

  defp valid_poll_interval(value) do
    executor_value(is_integer(value) and value >= 0, :poll_interval_ms)
  end

  defp start_deadline(settings) do
    case settings.monotonic_ms.() do
      now when is_integer(now) ->
        {:ok, Map.put(settings, :deadline_ms, now + settings.maximum_elapsed_ms)}

      _invalid ->
        {:error, {:invalid_admission_executor, :monotonic_ms}}
    end
  end

  defp poll_wait(settings, phase) do
    remaining = settings.deadline_ms - settings.monotonic_ms.()

    if remaining <= 0 do
      {:error, {:coop_timeout, phase}}
    else
      settings.sleep.(min(settings.poll_interval_ms, remaining))

      if settings.monotonic_ms.() >= settings.deadline_ms,
        do: {:error, {:coop_timeout, phase}},
        else: :ok
    end
  end

  defp valid_digest?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp executor_value(true, _field), do: :ok
  defp executor_value(false, field), do: {:error, {:invalid_admission_executor, field}}

  defp create_key(entry) do
    "responder:admission:create:#{entry.id}:g#{entry.execution_generation}"
  end

  defp session_external_ref(entry),
    do: "responder-admission:#{entry.id}:g#{entry.execution_generation}"

  defp validate_session(entry, session, settings, expected_id \\ nil)

  defp validate_session(entry, session, settings, expected_id),
    do: validate_session_state(entry, session, settings, expected_id, ["open"])

  defp validate_session_state(
         entry,
         %{
           "external_ref" => external_ref,
           "id" => id,
           "policy" => policy,
           "policy_digest" => policy_digest,
           "state" => state
         } = session,
         settings,
         expected_id,
         allowed_states
       ) do
    cond do
      not valid_ref?(id) or (expected_id != nil and id != expected_id) ->
        {:error, {:coop_protocol_error, :session_identity}}

      state not in allowed_states ->
        {:error, {:coop_protocol_error, :session_state}}

      policy != settings.policy or policy_digest != settings.policy_digest or
          external_ref != session_external_ref(entry) ->
        {:error, {:coop_protocol_error, :session_authority}}

      true ->
        {:ok, session}
    end
  end

  defp validate_session_state(_entry, _session, _settings, _expected_id, _allowed_states),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp session_revision(%{"revision" => revision})
       when is_integer(revision) and revision > 0,
       do: {:ok, revision}

  defp session_revision(_session), do: {:error, {:coop_protocol_error, :session_revision}}

  defp validate_turn(turn, expected_session_id, expected_turn_id \\ nil)

  defp validate_turn(
         %{"id" => id, "session_id" => session_id} = turn,
         expected_session_id,
         expected_turn_id
       ) do
    cond do
      not valid_ref?(id) ->
        {:error, {:coop_protocol_error, :turn_identity}}

      session_id != expected_session_id ->
        {:error, {:coop_protocol_error, :turn_session_identity}}

      expected_turn_id != nil and id != expected_turn_id ->
        {:error, {:coop_protocol_error, :turn_identity}}

      true ->
        {:ok, turn}
    end
  end

  defp validate_turn(_turn, _expected_session_id, _expected_turn_id),
    do: {:error, {:coop_protocol_error, :turn_resource}}

  defp turn_key(entry, _context) do
    "responder:admission:turn:#{entry.id}:g#{entry.execution_generation}:#{entry.admission_context_fingerprint}"
  end

  defp validation_key(entry, candidate_attempt, candidate_sha256, verdict),
    do:
      "responder:admission:validate:#{entry.id}:g#{entry.execution_generation}:a#{candidate_attempt}:v#{entry.validation_generation}:#{candidate_sha256}:#{verdict}"

  defp exact_validation_attempt(%{"validation_attempt" => attempt}, attempt), do: :ok

  defp exact_validation_attempt(_completed, _expected),
    do: {:error, {:coop_protocol_error, :validation_attempt}}

  defp close_key(entry),
    do: "responder:admission:close:#{entry.id}:g#{entry.execution_generation}"

  defp decision_ref(turn, sha256), do: "coop-admission:#{turn["id"]}:#{sha256}"

  defp validation_error({:error, {:coop_error, 503, "session_cleanup_error", _detail} = reason}),
    do: {:error, {:admission_validation_generation_spent, reason}}

  defp validation_error({:error, {:coop_error, 409, "operation_uncertain", _detail} = reason}),
    do: {:error, {:admission_execution_blocked, reason}}

  defp validation_error(error), do: error

  defp generation_spent(reason), do: {:error, {:admission_generation_spent, reason}}

  defp renew_lease(settings) do
    case settings.renew_lease.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, {:admission_execution_failed, :lease_renewal}}
    end
  end

  defp close_then(session, entry, settings, result) do
    case close_session(session, entry, settings) do
      :ok -> result
      {:error, _reason} = error -> error
    end
  end

  defp block_after_close(session, entry, settings, reason) do
    case close_session(session, entry, settings) do
      :ok ->
        {:error, {:admission_execution_blocked, reason}}

      {:error, cleanup_error} ->
        {:error,
         {:admission_execution_blocked, {reason, {:session_cleanup_failed, cleanup_error}}}}
    end
  end

  defp valid_ref?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp prepare_execution_session(entry, settings) do
    settings.prepare_execution_session.(entry, %{
      digest: settings.policy_digest,
      name: settings.policy
    })
    |> callback_result(:prepare_execution_session)
  end

  defp bind_execution_session(entry, %{"id" => session_id}, settings) do
    settings.bind_execution_session.(entry, session_id)
    |> callback_result(:bind_execution_session)
  end

  defp bind_execution_session(_entry, _session, _settings),
    do: {:error, {:coop_protocol_error, :session_identity}}

  defp settle_execution_session(entry, session_id, settings) do
    settings.settle_execution_session.(entry, session_id)
    |> callback_result(:settle_execution_session)
  end

  defp callback_result(:ok, _operation), do: :ok
  defp callback_result({:ok, _value}, _operation), do: :ok
  defp callback_result({:error, _reason} = error, _operation), do: error

  defp callback_result(_other, operation),
    do: {:error, {:admission_execution_failed, operation}}
end
