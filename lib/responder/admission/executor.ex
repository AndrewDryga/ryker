defmodule Responder.Admission.Executor do
  @moduledoc """
  Runs one durable ingress input through Coop's admission model turn.

  Coop enforces the JSON Schema and repairs malformed output in the native
  session. This module then checks the frozen host-owned candidate set. A
  semantic rejection goes back to the same Coop turn; a valid decision is
  committed through `Responder.Admission`.
  """

  alias Responder.Admission
  alias Responder.Admission.{Context, Decision, Prompt}
  alias Responder.CanonicalJSON
  alias Responder.Ingress.{Inbox, Input}

  @retryable_terminal_turn_states ~w(failed)
  @stopped_turn_states ~w(cancelled interrupted budget_exhausted)
  @waiting_turn_states ~w(queued starting running)
  @operation_waiting_states ~w(reserved running)

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(input_ref, options) do
    with {:ok, settings} <- settings(options),
         :ok <- renew_lease(settings),
         {:ok, entry} <- Inbox.fetch(input_ref),
         {:ok, entry, context} <- execution_context(input_ref, entry, settings),
         {:ok, session} <- ensure_session(entry, settings) do
      run_context(entry, session, context, settings)
    else
      :error -> {:error, {:admission_execution_failed, :input_not_found}}
      {:error, _reason} = error -> error
    end
  end

  defp run_context(entry, session, context, settings) do
    with {:ok, turn} <- ensure_turn(entry, session, context, settings),
         {:ok, decision, candidate_sha256} <- await_decision(turn, context, entry, settings),
         :ok <- close_session(session, entry, settings),
         {:ok, result} <-
           Admission.commit(context, decision, decision_ref(turn, candidate_sha256),
             lease_ref: settings.lease_ref
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
        session_from_operation(operation, key, settings, settings.max_polls)

      {:error, _reason} = error ->
        error
    end
  end

  defp create_session(entry, key, settings) do
    task = "responder-admission:#{entry.id}:g#{entry.execution_generation}"

    with :ok <- renew_lease(settings) do
      settings.api.create_session(settings.client, key, settings.policy, task)
    end
    |> case do
      {:ok, %{"session" => session}} when is_map(session) ->
        {:ok, session}

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        session_from_operation(operation, key, settings, settings.max_polls)

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :create_session_response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp session_from_operation(operation, key, settings, polls_left) do
    with {:ok, resource_id} <- operation_resource(operation, "session", key, settings, polls_left) do
      settings.api.get_session(settings.client, resource_id)
    end
  end

  defp ensure_turn(entry, session, context, settings) do
    key = turn_key(entry, context)

    with :ok <- renew_lease(settings) do
      settings.api.operation_by_key(settings.client, key)
    end
    |> case do
      :not_found -> submit_turn(session, context, key, settings)
      {:ok, operation} -> turn_from_operation(operation, session["id"], key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp submit_turn(session, context, key, settings) do
    prompt = context |> Prompt.build() |> CanonicalJSON.encode!()
    schema = Decision.json_schema(Input.allowed_actions(context.input))

    with :ok <- renew_lease(settings),
         {:ok, current_session} <- settings.api.get_session(settings.client, session["id"]),
         {:ok, response} <-
           settings.api.submit_turn(
             settings.client,
             session["id"],
             key,
             current_session["revision"],
             prompt,
             schema
           ) do
      case response do
        %{"turn" => turn} when is_map(turn) ->
          {:ok, turn}

        %{"operation" => operation} when is_map(operation) ->
          turn_from_operation(operation, session["id"], key, settings)

        _response ->
          {:error, {:coop_protocol_error, :submit_turn_response}}
      end
    end
  end

  defp turn_from_operation(operation, session_id, key, settings) do
    with {:ok, resource_id} <-
           operation_resource(operation, "turn", key, settings, settings.max_polls) do
      settings.api.get_turn(settings.client, session_id, resource_id)
    end
  end

  defp operation_resource(%{"state" => "succeeded"} = operation, type, _key, _settings, _left) do
    if operation["resource_type"] == type and valid_ref?(operation["resource_id"]),
      do: {:ok, operation["resource_id"]},
      else: {:error, {:coop_protocol_error, :operation_resource}}
  end

  defp operation_resource(%{"state" => "failed"} = operation, _type, _key, _settings, _left) do
    generation_spent(
      {:coop_operation_failed, operation["error_code"] || "failed",
       operation["error_detail"] || "Coop operation failed"}
    )
  end

  defp operation_resource(%{"state" => "uncertain"} = operation, _type, _key, _settings, _left) do
    {:error,
     {:admission_execution_blocked,
      {:coop_operation_uncertain, operation["error_code"] || "uncertain",
       operation["error_detail"] || "Coop operation outcome is uncertain"}}}
  end

  defp operation_resource(%{"state" => state}, type, key, settings, left)
       when state in @operation_waiting_states and left > 0 do
    with :ok <- renew_lease(settings) do
      settings.sleep.(settings.poll_interval_ms)

      case settings.api.operation_by_key(settings.client, key) do
        {:ok, operation} -> operation_resource(operation, type, key, settings, left - 1)
        :not_found -> {:error, {:coop_protocol_error, :operation_disappeared}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp operation_resource(%{"state" => state}, _type, _key, _settings, 0)
       when state in @operation_waiting_states,
       do: {:error, {:coop_timeout, :operation}}

  defp operation_resource(_operation, _type, _key, _settings, _left),
    do: {:error, {:coop_protocol_error, :operation_state}}

  defp await_decision(turn, context, entry, settings) do
    await_decision(turn, context, entry, settings, settings.max_polls)
  end

  defp await_decision(
         %{"state" => "awaiting_validation", "candidate" => candidate} = turn,
         context,
         entry,
         settings,
         left
       )
       when is_map(candidate) do
    candidate_decision(turn, candidate, context, entry, settings, left)
  end

  defp await_decision(
         %{
           "state" => "completed",
           "assistant_message" => message,
           "validation_candidate_sha256" => candidate_sha256,
           "validation_receipt" => validation_receipt
         },
         context,
         _entry,
         _settings,
         _left
       )
       when is_binary(message) and is_binary(candidate_sha256) and
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

  defp await_decision(
         %{"state" => "completed"},
         _context,
         _entry,
         _settings,
         _left
       ),
       do: generation_spent({:coop_protocol_error, :validation_receipt})

  defp await_decision(%{"state" => state} = turn, _context, _entry, _settings, _left)
       when state in @retryable_terminal_turn_states do
    generation_spent({:coop_turn_failed, state, turn["error_code"], turn["error_detail"]})
  end

  defp await_decision(%{"state" => state} = turn, _context, _entry, _settings, _left)
       when state in @stopped_turn_states do
    {:error,
     {:admission_execution_stopped,
      {:coop_turn_stopped, state, turn["error_code"], turn["error_detail"]}}}
  end

  defp await_decision(%{"state" => state} = turn, context, entry, settings, left)
       when state in @waiting_turn_states and left > 0 do
    with :ok <- renew_lease(settings) do
      settings.sleep.(settings.poll_interval_ms)

      case settings.api.get_turn(settings.client, turn["session_id"], turn["id"]) do
        {:ok, current} -> await_decision(current, context, entry, settings, left - 1)
        {:error, _reason} = error -> error
      end
    end
  end

  defp await_decision(%{"state" => state}, _context, _entry, _settings, 0)
       when state in @waiting_turn_states,
       do: {:error, {:coop_timeout, :turn}}

  defp await_decision(_turn, _context, _entry, _settings, _left),
    do: {:error, {:coop_protocol_error, :turn_state}}

  defp candidate_decision(turn, candidate, context, entry, settings, left) do
    with {:ok, message, candidate_sha256} <- candidate_fields(candidate) do
      case parse_and_validate(message, context) do
        {:ok, decision} ->
          accept_candidate(turn, decision, candidate_sha256, context, entry, settings, left)

        {:error, reason} ->
          reject_candidate(turn, candidate_sha256, reason, context, entry, settings, left)
      end
    end
  end

  defp accept_candidate(turn, decision, candidate_sha256, context, entry, settings, left) do
    key = validation_key(entry, candidate_sha256, "accept")

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
        with {:ok, completed_decision, completed_sha256} <-
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

  defp reject_candidate(turn, candidate_sha256, reason, context, entry, settings, left) do
    key = validation_key(entry, candidate_sha256, "reject")
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
      {:ok, %{"turn" => current}} -> await_decision(current, context, entry, settings, left)
      {:ok, _response} -> {:error, {:coop_protocol_error, :validation_response}}
      {:error, _reason} = error -> validation_error(error)
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

  defp candidate_fields(%{"message" => message, "sha256" => candidate_sha256})
       when is_binary(message) and is_binary(candidate_sha256) do
    if sha256(message) == candidate_sha256,
      do: {:ok, message, candidate_sha256},
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

  defp violation({:invalid_decision, field}) do
    "The decision field #{field} does not satisfy the attached response schema."
  end

  defp violation({:invalid_candidate, :json_object}) do
    "Return exactly one JSON object matching the attached response schema."
  end

  defp violation(reason), do: "The host rejected this decision: #{inspect(reason)}"

  defp close_session(session, entry, settings) do
    with :ok <- renew_lease(settings),
         {:ok, current} <- settings.api.get_session(settings.client, session["id"]) do
      close_current_session(current, entry, settings)
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
      {:ok, %{"session" => %{"state" => state}}} when state in ["closed", "discarded"] ->
        :ok

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
      :candidate_limit,
      :client,
      :continuation_window,
      :history_window,
      :lease_ref,
      :max_polls,
      :now,
      :policy,
      :poll_interval_ms,
      :renew_lease,
      :sleep
    ]

    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      validate_settings(%{
        api: Keyword.get(options, :api, Responder.Coop.Client),
        candidate_limit: Keyword.get(options, :candidate_limit, 20),
        client: Keyword.fetch!(options, :client),
        continuation_window: Keyword.get(options, :continuation_window, 30 * 60),
        history_window: Keyword.get(options, :history_window, 30 * 24 * 60 * 60),
        lease_ref: Keyword.fetch!(options, :lease_ref),
        max_polls: Keyword.get(options, :max_polls, 600),
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        policy: Keyword.fetch!(options, :policy),
        poll_interval_ms: Keyword.get(options, :poll_interval_ms, 250),
        renew_lease: Keyword.fetch!(options, :renew_lease),
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
         :ok <- executor_value(is_function(settings.now, 0), :now),
         :ok <- executor_value(is_function(settings.renew_lease, 0), :renew_lease),
         :ok <- executor_value(is_function(settings.sleep, 1), :sleep),
         :ok <- executor_value(valid_ref?(settings.policy), :policy),
         :ok <- executor_value(valid_ref?(settings.lease_ref), :lease_ref),
         :ok <- executor_value(positive?(settings.candidate_limit), :candidate_limit),
         :ok <- executor_value(positive?(settings.continuation_window), :continuation_window),
         :ok <- valid_history_window(settings),
         :ok <- executor_value(positive?(settings.max_polls), :max_polls),
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

  defp executor_value(true, _field), do: :ok
  defp executor_value(false, field), do: {:error, {:invalid_admission_executor, field}}

  defp create_key(entry) do
    "responder:admission:create:#{entry.id}:g#{entry.execution_generation}"
  end

  defp turn_key(entry, _context) do
    "responder:admission:turn:#{entry.id}:g#{entry.execution_generation}:#{entry.admission_context_fingerprint}"
  end

  defp validation_key(entry, candidate_sha256, verdict),
    do:
      "responder:admission:validate:#{entry.id}:g#{entry.execution_generation}:v#{entry.validation_generation}:#{candidate_sha256}:#{verdict}"

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
end
