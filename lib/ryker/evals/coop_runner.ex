defmodule Ryker.Evals.CoopRunner do
  @moduledoc """
  Executes a tool-free model-world quality judgment against a real Coop policy.

  A judge case carries the sanitized evidence of one completed model-world run
  and no tools. Each case gets a fresh session, exact output schema, and unique
  operation identity. A judgment the host cannot read is rejected for repair in
  the same turn, and the accepted judgment is scored on its bounded rubric
  verdict, never on explanatory prose.
  """

  alias Ryker.Evals.WorldJudgeCase
  alias Ryker.Reference
  alias Ryker.Retention.Plan

  @waiting_operations ~w(reserved running)
  @waiting_turns ~w(queued starting running)
  @terminal_turns ~w(completed failed cancelled interrupted budget_exhausted)
  @fields [
    :api,
    :client,
    :id_generator,
    :max_polls,
    :policy,
    :policy_digest,
    :poll_interval_ms,
    :sleep
  ]

  @type eval_case :: WorldJudgeCase.t()

  @spec run([eval_case()], keyword() | map()) :: {:ok, map()} | {:error, term()}
  def run(cases, options) when is_list(cases) do
    with {:ok, settings} <- settings(options) do
      results = Enum.map(cases, &execute_case(&1, settings))

      {:ok,
       %{
         failed: Enum.count(results, &(&1.status == :failed)),
         passed: Enum.count(results, &(&1.status == :passed)),
         results: results,
         total: length(results)
       }}
    end
  end

  def run(_cases, _options), do: {:error, {:invalid_eval_runner, :cases}}

  @spec run_case(eval_case(), keyword() | map()) :: map()
  def run_case(%WorldJudgeCase{} = eval, options) when is_list(options) or is_map(options) do
    case settings(options) do
      {:ok, settings} -> execute_case(eval, settings)
      {:error, reason} -> failed(eval, reason)
    end
  end

  defp execute_case(%WorldJudgeCase{} = eval, settings) do
    run_ref = settings.id_generator.()
    external_ref = "ryker-eval:world-judge:#{run_ref}:#{eval.eval_id}"
    create_key = "ryker:eval:world-judge:#{run_ref}:create"

    with :ok <- reference(run_ref, :run_ref),
         :ok <- reference(external_ref, :external_ref),
         {:ok, session} <- create_session(create_key, external_ref, settings),
         {:ok, turn} <- submit_turn("world-judge", run_ref, session, eval, settings),
         {:ok, turn, candidate} <- await_candidate(session, turn, settings),
         {:ok, result} <- judge_candidate(eval, run_ref, session, turn, candidate, settings),
         :ok <- close_session("world-judge", run_ref, session, settings),
         :ok <- discard_clean_session("world-judge", run_ref, session, settings) do
      Map.merge(result, %{
        eval_id: eval.eval_id,
        session_id: session["id"],
        turn_id: turn["id"]
      })
    else
      {:error, reason} -> failed(eval, reason)
    end
  rescue
    error -> failed(eval, {:world_judge_runner_exception, Exception.message(error)})
  catch
    kind, reason -> failed(eval, {:world_judge_runner_caught, kind, inspect(reason)})
  end

  defp create_session(key, external_ref, settings) do
    case settings.api.create_session(
           settings.client,
           key,
           settings.policy,
           external_ref,
           nil
         ) do
      {:ok, %{"session" => session}} when is_map(session) ->
        validate_session(session, external_ref, nil, ["open"], settings)

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        with {:ok, session_id} <-
               await_operation(operation, key, "CreateRemoteSession", "session", settings),
             {:ok, session} <- settings.api.get_session(settings.client, session_id) do
          validate_session(session, external_ref, session_id, ["open"], settings)
        end

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :create_session_response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp submit_turn(namespace, run_ref, session, eval, settings) do
    key = "ryker:eval:#{namespace}:#{run_ref}:turn"

    with {:ok, current} <- settings.api.get_session(settings.client, session["id"]),
         {:ok, current} <-
           validate_session(
             current,
             session["external_ref"],
             session["id"],
             ["open"],
             settings
           ),
         {:ok, revision} <- revision(current),
         {:ok, response} <-
           settings.api.submit_turn(
             settings.client,
             session["id"],
             key,
             revision,
             eval.prompt,
             eval.schema
           ) do
      submit_response(response, session, key, settings)
    end
  end

  defp submit_response(%{"turn" => turn}, session, _key, _settings) when is_map(turn),
    do: validate_turn(turn, session["id"], nil)

  defp submit_response(%{"operation" => operation}, session, key, settings)
       when is_map(operation) do
    with {:ok, turn_id} <- await_operation(operation, key, "SubmitTurn", "turn", settings),
         {:ok, turn} <- settings.api.get_turn(settings.client, session["id"], turn_id) do
      validate_turn(turn, session["id"], turn_id)
    end
  end

  defp submit_response(_response, _session, _key, _settings),
    do: {:error, {:coop_protocol_error, :submit_turn_response}}

  defp await_operation(operation, key, method, type, settings) do
    await_operation(operation, key, method, type, settings.max_polls, settings)
  end

  defp await_operation(
         %{
           "method" => method,
           "resource_id" => resource_id,
           "resource_type" => type,
           "state" => "succeeded"
         },
         _key,
         method,
         type,
         _left,
         _settings
       ) do
    with :ok <- reference(resource_id, :resource_id), do: {:ok, resource_id}
  end

  defp await_operation(
         %{
           "error_code" => code,
           "error_detail" => detail,
           "method" => method,
           "state" => "failed"
         },
         _key,
         method,
         _type,
         _left,
         _settings
       ),
       do: {:error, {:coop_operation_failed, code, detail}}

  defp await_operation(
         %{"method" => method, "state" => state},
         key,
         method,
         type,
         left,
         settings
       )
       when state in @waiting_operations and left > 0 do
    settings.sleep.(settings.poll_interval_ms)

    case settings.api.operation_by_key(settings.client, key) do
      {:ok, operation} ->
        await_operation(operation, key, method, type, left - 1, settings)

      :not_found ->
        {:error, {:coop_protocol_error, :operation_disappeared}}

      {:error, _reason} = error ->
        error
    end
  end

  defp await_operation(
         %{"method" => method, "state" => state},
         _key,
         method,
         _type,
         0,
         _settings
       )
       when state in @waiting_operations,
       do: {:error, {:coop_timeout, :operation}}

  defp await_operation(%{"method" => _method}, _key, _expected, _type, _left, _settings),
    do: {:error, {:coop_protocol_error, :operation_method}}

  defp await_operation(_operation, _key, _method, _type, _left, _settings),
    do: {:error, {:coop_protocol_error, :operation_state}}

  defp await_candidate(session, turn, settings) do
    await_candidate(session, turn, settings.max_polls, settings)
  end

  defp await_candidate(
         session,
         %{"candidate" => candidate, "state" => "awaiting_validation"} = turn,
         _left,
         _settings
       )
       when is_map(candidate) do
    with {:ok, turn} <- validate_turn(turn, session["id"], turn["id"]),
         {:ok, candidate} <- validate_candidate(candidate) do
      {:ok, turn, candidate}
    end
  end

  defp await_candidate(session, %{"state" => state} = turn, left, settings)
       when state in @waiting_turns and left > 0 do
    settings.sleep.(settings.poll_interval_ms)

    with {:ok, current} <-
           settings.api.get_turn(settings.client, session["id"], turn["id"]),
         {:ok, current} <- validate_turn(current, session["id"], turn["id"]) do
      await_candidate(session, current, left - 1, settings)
    end
  end

  defp await_candidate(_session, %{"state" => state}, 0, _settings)
       when state in @waiting_turns,
       do: {:error, {:coop_timeout, :turn}}

  defp await_candidate(_session, %{"state" => state}, _left, _settings)
       when state in @terminal_turns,
       do: {:error, {:coop_turn_terminal_without_candidate, state}}

  defp await_candidate(_session, _turn, _left, _settings),
    do: {:error, {:coop_protocol_error, :turn_state}}

  defp validate_candidate(
         %{"attempt" => attempt, "message" => message, "sha256" => digest} = candidate
       )
       when map_size(candidate) == 3 and is_integer(attempt) and attempt > 0 and
              is_binary(message) and
              is_binary(digest) do
    if sha256(message) == digest,
      do: {:ok, candidate},
      else: {:error, {:coop_protocol_error, :candidate_digest}}
  end

  defp validate_candidate(_candidate), do: {:error, {:coop_protocol_error, :candidate}}

  defp judge_candidate(eval, run_ref, session, turn, candidate, settings) do
    case WorldJudgeCase.validate(eval, candidate["message"]) do
      {:accept, judgment} ->
        with {:ok, _completed} <-
               accept_candidate("world-judge", run_ref, session, turn, candidate, settings) do
          {:ok,
           %{
             decision: judgment.document,
             reason: if(judgment.passed, do: nil, else: :quality_rubric_failed),
             status: if(judgment.passed, do: :passed, else: :failed)
           }}
        end

      {:reject, violations} ->
        with :ok <- candidate_attempt_available(candidate),
             {:ok, next_turn} <-
               reject_candidate(
                 "world-judge",
                 run_ref,
                 session,
                 turn,
                 candidate,
                 violations,
                 settings
               ),
             {:ok, next_turn, next_candidate} <- await_candidate(session, next_turn, settings) do
          judge_candidate(eval, run_ref, session, next_turn, next_candidate, settings)
        end
    end
  end

  defp candidate_attempt_available(%{"attempt" => attempt}) when attempt < 20, do: :ok

  defp candidate_attempt_available(%{"attempt" => attempt}),
    do: {:error, {:eval_candidate_limit, attempt}}

  defp accept_candidate(namespace, run_ref, session, turn, candidate, settings) do
    key =
      "ryker:eval:#{namespace}:#{run_ref}:validate:#{candidate["attempt"]}:#{candidate["sha256"]}:accept"

    with {:ok, completed} <-
           validate_remote_candidate(
             session,
             turn,
             key,
             candidate,
             :accept,
             settings
           ),
         :ok <- completed_candidate(completed, candidate) do
      {:ok, completed}
    end
  end

  defp reject_candidate(namespace, run_ref, session, turn, candidate, violations, settings) do
    key =
      "ryker:eval:#{namespace}:#{run_ref}:validate:#{candidate["attempt"]}:#{candidate["sha256"]}:reject"

    with {:ok, current} <-
           validate_remote_candidate(
             session,
             turn,
             key,
             candidate,
             {:reject, violations},
             settings
           ),
         :ok <- rejection_advanced(current, candidate) do
      {:ok, current}
    end
  end

  defp validate_remote_candidate(session, turn, key, candidate, verdict, settings) do
    case settings.api.validate_candidate(
           settings.client,
           session["id"],
           turn["id"],
           key,
           candidate["sha256"],
           verdict
         ) do
      {:ok, %{"turn" => current}} when is_map(current) ->
        validate_turn(current, session["id"], turn["id"])

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        with {:ok, turn_id} <-
               await_operation(
                 operation,
                 key,
                 "ValidateTurnCandidate",
                 "turn_validation",
                 settings
               ),
             true <- turn_id == turn["id"],
             {:ok, current} <-
               settings.api.get_turn(settings.client, session["id"], turn["id"]),
             {:ok, current} <- validate_turn(current, session["id"], turn["id"]) do
          {:ok, current}
        else
          false -> {:error, {:coop_protocol_error, :validation_turn_identity}}
          {:error, _reason} = error -> error
        end

      {:ok, _response} ->
        {:error, {:coop_protocol_error, :validation_response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp rejection_advanced(%{"candidate" => next, "state" => "awaiting_validation"}, candidate)
       when is_map(next) do
    with {:ok, next} <- validate_candidate(next),
         true <- next["attempt"] > candidate["attempt"] do
      :ok
    else
      false -> {:error, {:coop_protocol_error, :validation_rejection_not_applied}}
      {:error, _reason} = error -> error
    end
  end

  defp rejection_advanced(%{"state" => state}, _candidate) when state in @waiting_turns,
    do: :ok

  defp rejection_advanced(_turn, _candidate),
    do: {:error, {:coop_protocol_error, :validation_rejection_state}}

  defp completed_candidate(
         %{
           "assistant_message" => message,
           "state" => "completed",
           "validation_attempt" => attempt,
           "validation_candidate_sha256" => digest,
           "validation_receipt" => receipt
         },
         %{"attempt" => attempt, "message" => message, "sha256" => digest}
       ) do
    reference(receipt, :validation_receipt)
  end

  defp completed_candidate(_completed, _candidate),
    do: {:error, {:coop_protocol_error, :validation_receipt}}

  defp close_session(namespace, run_ref, session, settings) do
    with {:ok, current} <- settings.api.get_session(settings.client, session["id"]),
         {:ok, current} <-
           validate_session(
             current,
             session["external_ref"],
             session["id"],
             ~w(open exhausted closed discarded),
             settings
           ) do
      case current["state"] do
        state when state in ["closed", "discarded"] ->
          :ok

        _open ->
          close_open_session(namespace, run_ref, session, current, settings)
      end
    end
  end

  defp close_open_session(namespace, run_ref, session, current, settings) do
    with {:ok, revision} <- revision(current),
         {:ok, %{"session" => closed}} <-
           settings.api.close_session(
             settings.client,
             session["id"],
             "ryker:eval:#{namespace}:#{run_ref}:close",
             revision
           ),
         {:ok, _closed} <-
           validate_session(
             closed,
             session["external_ref"],
             session["id"],
             ~w(closed discarded),
             settings
           ) do
      :ok
    else
      {:ok, _response} -> {:error, {:coop_protocol_error, :close_session_response}}
      {:error, _reason} = error -> error
    end
  end

  defp discard_clean_session(namespace, run_ref, session, settings) do
    with {:ok, current} <- settings.api.get_session(settings.client, session["id"]),
         {:ok, current} <-
           validate_session(
             current,
             session["external_ref"],
             session["id"],
             ~w(closed discarded),
             settings
           ) do
      case current["state"] do
        "discarded" -> :ok
        "closed" -> plan_and_discard(namespace, run_ref, session, current, settings)
      end
    end
  end

  defp plan_and_discard(namespace, run_ref, session, current, settings) do
    plan_key = "ryker:eval:#{namespace}:#{run_ref}:discard-plan"
    discard_key = "ryker:eval:#{namespace}:#{run_ref}:discard"

    with {:ok, revision} <- revision(current),
         {:ok, plan_response} <-
           settings.api.plan_discard(
             settings.client,
             session["id"],
             plan_key,
             revision,
             false,
             false
           ),
         {:ok, plan} <- Plan.prepare(plan_response, session["id"], revision, false),
         true <- Plan.discardable?(plan),
         {:ok, discard_response} <-
           settings.api.discard_session(
             settings.client,
             session["id"],
             discard_key,
             plan["operation_id"]
           ),
         :ok <- discard_response(discard_response, session, settings) do
      :ok
    else
      false -> {:error, {:eval_workspace_not_discardable, session["id"]}}
      {:error, _reason} = error -> error
    end
  end

  defp discard_response(%{"operation" => operation, "session" => discarded}, session, settings)
       when is_map(operation) and is_map(discarded) do
    with :ok <- exact_operation(operation, "Discard", "session", session["id"]),
         {:ok, _discarded} <-
           validate_session(
             discarded,
             session["external_ref"],
             session["id"],
             ["discarded"],
             settings
           ) do
      :ok
    end
  end

  defp discard_response(_response, _session, _settings),
    do: {:error, {:coop_protocol_error, :discard_response}}

  defp exact_operation(
         %{
           "id" => id,
           "method" => method,
           "resource_id" => resource_id,
           "resource_type" => resource_type,
           "state" => "succeeded"
         },
         method,
         resource_type,
         resource_id
       ),
       do: reference(id, :operation_id)

  defp exact_operation(_operation, _method, _resource_type, _resource_id),
    do: {:error, {:coop_protocol_error, :operation_identity}}

  defp validate_session(
         %{
           "external_ref" => external_ref,
           "id" => id,
           "policy" => policy,
           "policy_digest" => digest,
           "state" => state
         } = session,
         external_ref,
         expected_id,
         states,
         settings
       ) do
    with :ok <- validate_session_identity(id, expected_id),
         :ok <- validate_session_authority(policy, digest, settings),
         :ok <- validate_session_repository_authority(session),
         :ok <- validate_session_project_authority(session),
         :ok <- validate_session_state(state, states) do
      {:ok, session}
    end
  end

  defp validate_session(_session, _external_ref, _expected_id, _states, _settings),
    do: {:error, {:coop_protocol_error, :session_identity}}

  defp validate_session_identity(id, expected_id) do
    if reference(id, :session_id) == :ok and (is_nil(expected_id) or id == expected_id),
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_identity}}
  end

  defp validate_session_authority(policy, digest, settings) do
    if policy == settings.policy and digest == settings.policy_digest,
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_authority}}
  end

  defp validate_session_repository_authority(%{"repository_read_only" => true}), do: :ok

  defp validate_session_repository_authority(_session),
    do: {:error, {:coop_protocol_error, :session_repository_write_authority}}

  defp validate_session_project_authority(%{"project_env" => false, "project_mcp" => false}),
    do: :ok

  defp validate_session_project_authority(_session),
    do: {:error, {:coop_protocol_error, :session_project_authority}}

  defp validate_session_state(state, states) do
    if state in states,
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_state}}
  end

  defp validate_turn(%{"id" => id, "session_id" => session_id} = turn, session_id, expected_id) do
    cond do
      reference(id, :turn_id) != :ok ->
        {:error, {:coop_protocol_error, :turn_identity}}

      expected_id && id != expected_id ->
        {:error, {:coop_protocol_error, :turn_identity}}

      true ->
        {:ok, turn}
    end
  end

  defp validate_turn(_turn, _session_id, _expected_id),
    do: {:error, {:coop_protocol_error, :turn_identity}}

  defp revision(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  defp revision(_session), do: {:error, {:coop_protocol_error, :session_revision}}

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> settings(),
      else: {:error, {:invalid_eval_runner, :options}}
  end

  defp settings(%{} = options) do
    if Map.keys(options) -- @fields == [] do
      settings = %{
        api: Map.get(options, :api, Ryker.Coop.Client),
        client: Map.get(options, :client),
        id_generator: Map.get(options, :id_generator, &Ecto.UUID.generate/0),
        max_polls: Map.get(options, :max_polls, 2_400),
        policy: Map.get(options, :policy),
        policy_digest: Map.get(options, :policy_digest),
        poll_interval_ms: Map.get(options, :poll_interval_ms, 250),
        sleep: Map.get(options, :sleep, &Process.sleep/1)
      }

      with true <- is_atom(settings.api),
           true <- not is_nil(settings.client),
           true <- is_function(settings.id_generator, 0),
           true <- is_integer(settings.max_polls) and settings.max_polls > 0,
           :ok <- reference(settings.policy, :policy),
           true <- digest?(settings.policy_digest),
           true <- is_integer(settings.poll_interval_ms) and settings.poll_interval_ms >= 0,
           true <- is_function(settings.sleep, 1) do
        {:ok, settings}
      else
        _invalid -> {:error, {:invalid_eval_runner, :options}}
      end
    else
      {:error, {:invalid_eval_runner, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_eval_runner, :options}}

  defp reference(value, _field) when is_binary(value) and byte_size(value) in 1..2_048 do
    if Reference.valid?(value, 2_048), do: :ok, else: {:error, {:invalid_eval_runner, :reference}}
  end

  defp reference(_value, field), do: {:error, {:invalid_eval_runner, field}}

  defp digest?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp failed(eval, reason) do
    %{decision: nil, eval_id: eval.eval_id, reason: reason, status: :failed}
  end
end
