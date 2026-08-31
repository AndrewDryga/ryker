defmodule Responder.TestSupport.FakeCoopAPI do
  @moduledoc false

  @behaviour Responder.Coop.API

  def start_link(candidates, options \\ []) do
    resume_operations = Keyword.get(options, :resume_operations, false)
    {turn, candidates} = resumed_turn(candidates, resume_operations)

    Agent.start_link(fn ->
      %{
        async_create: Keyword.get(options, :async_create, false),
        async_operations_running: Keyword.get(options, :async_operations_running, false),
        async_submit: Keyword.get(options, :async_submit, false),
        candidates: candidates,
        accepted_candidate_override: Keyword.get(options, :accepted_candidate_override),
        close_after_validation: Keyword.get(options, :close_after_validation, false),
        close_keys: [],
        closed: false,
        discard_keys: [],
        discard_plan_keys: [],
        discarded: false,
        create_keys: [],
        exhaust_after_validation: Keyword.get(options, :exhaust_after_validation, false),
        fail_create: Keyword.get(options, :fail_create, false),
        fail_first_close: Keyword.get(options, :fail_first_close, false),
        failed_close_key: nil,
        fail_first_operation: Keyword.get(options, :fail_first_operation, false),
        failed_operation_key: nil,
        fail_first_turn: Keyword.get(options, :fail_first_turn, false),
        fail_first_turn_response: Keyword.get(options, :fail_first_turn_response, false),
        first_turn_state: Keyword.get(options, :first_turn_state, "failed"),
        failed_turn_key: nil,
        lost_turn_response_key: nil,
        fail_first_validation: Keyword.get(options, :fail_first_validation, false),
        first_validation_error:
          Keyword.get(
            options,
            :first_validation_error,
            {:coop_error, 503, "session_cleanup_error", "runtime cleanup failed"}
          ),
        failed_validation_key: nil,
        known_operations: %{},
        omit_validation_digest: Keyword.get(options, :omit_validation_digest, false),
        omit_validation_receipt: Keyword.get(options, :omit_validation_receipt, false),
        operation_calls: %{},
        operation_mode: Keyword.get(options, :operation_mode, :succeeded),
        resume_operations: resume_operations,
        schema: nil,
        session: %{
          "external_ref" => nil,
          "id" => "remote_test",
          "policy" => nil,
          "policy_digest" => String.duplicate("a", 64),
          "project_env" => Keyword.get(options, :project_env, false),
          "project_mcp" => Keyword.get(options, :project_mcp, false),
          "repository_read_only" => Keyword.get(options, :repository_read_only, true),
          "revision" => 1,
          "state" => "open"
        },
        submit_count: 0,
        turn_id_override: Keyword.get(options, :turn_id_override),
        turn_session_id_override: Keyword.get(options, :turn_session_id_override),
        turn_keys: [],
        turn: turn,
        turn_wait_polls: Keyword.get(options, :turn_wait_polls, 0),
        validation_keys: [],
        validation_responses: %{},
        validations: []
      }
    end)
  end

  def state(agent), do: Agent.get(agent, & &1)
  def allow_create(agent), do: Agent.update(agent, &%{&1 | fail_create: false})

  @impl true
  def operation_by_key(agent, key) do
    Agent.get_and_update(agent, fn state ->
      calls = Map.update(state.operation_calls, key, 1, &(&1 + 1))
      state = %{state | operation_calls: calls}

      operation_for_key(state, key, calls[key])
    end)
  end

  @impl true
  def create_session(agent, key, policy, task) do
    Agent.get_and_update(agent, fn state ->
      session =
        Map.merge(state.session, %{
          "external_ref" => task,
          "policy" => policy,
          "state" => "open"
        })

      response =
        cond do
          state.fail_create ->
            {:error, {:coop_unavailable, :simulated}}

          state.async_create ->
            {:ok,
             %{
               "operation" =>
                 "CreateRemoteSession"
                 |> succeeded_operation("session", session["id"])
                 |> maybe_running_operation(state.async_operations_running)
             }}

          true ->
            {:ok, %{"session" => session}}
        end

      operations =
        if state.fail_create,
          do: state.known_operations,
          else:
            Map.put(
              state.known_operations,
              key,
              succeeded_operation("CreateRemoteSession", "session", session["id"])
            )

      {response,
       %{
         state
         | create_keys: state.create_keys ++ [key],
           known_operations: operations,
           session: session
       }}
    end)
  end

  @impl true
  def fence_create_session(agent, key, _policy, _task),
    do: fence_operation(agent, key, "CreateRemoteSession")

  @impl true
  def get_session(agent, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

  @impl true
  def submit_turn(agent, session_id, key, _revision, _prompt, schema) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | turn_keys: state.turn_keys ++ [key]}

      if state.fail_first_turn and is_nil(state.failed_turn_key) do
        failed = failed_turn(session_id, state.first_turn_state)

        operation =
          succeeded_operation("SubmitTurn", "turn", failed["id"])

        next = %{
          state
          | failed_turn_key: key,
            known_operations: Map.put(state.known_operations, key, operation),
            schema: schema,
            submit_count: state.submit_count + 1,
            turn: failed
        }

        {{:ok, %{"turn" => failed}}, next}
      else
        {response, next} = successful_turn_submission(state, session_id, key, schema)
        maybe_lose_turn_response(state, next, key, response)
      end
    end)
  end

  @impl true
  def fence_submit_turn(agent, _session_id, key, _revision, _prompt, _schema),
    do: fence_operation(agent, key, "SubmitTurn")

  defp maybe_lose_turn_response(state, next, key, response) do
    if state.fail_first_turn_response and is_nil(state.lost_turn_response_key) do
      {{:error, {:coop_unavailable, :simulated_turn_response_loss}},
       %{next | lost_turn_response_key: key}}
    else
      {response, next}
    end
  end

  @impl true
  def get_turn(agent, _session_id, _turn_id) do
    Agent.get_and_update(agent, fn state ->
      if state.turn_wait_polls > 0 do
        queued = state.turn |> Map.put("state", "running") |> Map.put("candidate", nil)
        {{:ok, queued}, %{state | turn_wait_polls: state.turn_wait_polls - 1}}
      else
        {{:ok, state.turn}, state}
      end
    end)
  end

  @impl true
  def get_output_artifact(_agent, _session_id, _turn_id, _artifact_id),
    do: {:error, {:coop_error, 404, "artifact_not_found", "artifact not found"}}

  @impl true
  def cancel_turn(agent, _session_id, _turn_id, _key, _expected_revision) do
    Agent.get_and_update(agent, fn state ->
      cancelled =
        (state.turn || %{"id" => "turn_test", "session_id" => state.session["id"]})
        |> Map.put("candidate", nil)
        |> Map.put("state", "cancelled")

      {{:ok, %{"turn" => cancelled}}, %{state | turn: cancelled}}
    end)
  end

  @impl true
  def validate_candidate(agent, _session_id, _turn_id, key, sha256, :accept) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | validation_keys: state.validation_keys ++ [key]}
      error = state.first_validation_error

      cond do
        Map.has_key?(state.validation_responses, key) ->
          {{:ok, state.validation_responses[key]}, state}

        state.fail_first_validation and is_nil(state.failed_validation_key) ->
          {{:error, error}, %{state | failed_validation_key: key}}

        state.fail_first_validation and state.failed_validation_key == key ->
          {{:error, error}, state}

        true ->
          accept_candidate(state, key, sha256)
      end
    end)
  end

  def validate_candidate(agent, session_id, _turn_id, key, sha256, {:reject, violations}) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | validation_keys: state.validation_keys ++ [key]}

      case Map.fetch(state.validation_responses, key) do
        {:ok, response} ->
          {{:ok, response}, state}

        :error ->
          [candidate | remaining] = state.candidates
          attempt = state.turn["candidate"]["attempt"] + 1

          current =
            session_id
            |> awaiting_turn(candidate, attempt)
            |> override_turn_identity(state)

          validation = %{sha256: sha256, verdict: :reject, violations: violations}
          response = %{"turn" => current}

          next = %{
            state
            | candidates: remaining,
              turn: current,
              validation_responses: Map.put(state.validation_responses, key, response),
              validations: state.validations ++ [validation]
          }

          {{:ok, response}, next}
      end
    end)
  end

  @impl true
  def close_session(agent, _session_id, key, _revision) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | close_keys: state.close_keys ++ [key]}

      cond do
        state.fail_first_close and is_nil(state.failed_close_key) ->
          closed = close_state(state)

          {{:error, {:coop_unavailable, :simulated_close_response_loss}},
           %{closed | failed_close_key: key}}

        state.failed_close_key == key ->
          {{:ok, %{"session" => state.session}}, state}

        true ->
          closed = close_state(state)
          {{:ok, %{"session" => closed.session}}, closed}
      end
    end)
  end

  @impl true
  def plan_discard(agent, session_id, key, revision, false, false) do
    Agent.get_and_update(agent, fn state ->
      operation_id = "op_plan_#{key}"

      response = %{
        "operation" => %{
          "id" => operation_id,
          "method" => "PlanDiscard",
          "resource_id" => session_id,
          "resource_type" => "discard_plan",
          "state" => "succeeded"
        },
        "plan" => %{
          "operation_id" => operation_id,
          "plan" => %{
            "revision" => revision,
            "session_id" => session_id,
            "workspace" => %{
              "accepted_dirty" => false,
              "accepted_unmerged" => false,
              "branch" => "coop/eval",
              "dirty" => false,
              "head" => String.duplicate("b", 40),
              "running" => false,
              "status_digest" => String.duplicate("c", 64),
              "unmerged" => false
            }
          }
        }
      }

      {{:ok, response}, %{state | discard_plan_keys: state.discard_plan_keys ++ [key]}}
    end)
  end

  @impl true
  def discard_session(agent, session_id, key, _plan_operation_id) do
    Agent.get_and_update(agent, fn state ->
      discarded =
        state.session
        |> Map.put("state", "discarded")
        |> Map.update!("revision", &(&1 + 1))

      response = %{
        "operation" => %{
          "id" => "op_discard_#{key}",
          "method" => "Discard",
          "resource_id" => session_id,
          "resource_type" => "session",
          "state" => "succeeded"
        },
        "session" => discarded
      }

      {{:ok, response},
       %{
         state
         | discard_keys: state.discard_keys ++ [key],
           discarded: true,
           session: discarded
       }}
    end)
  end

  defp close_state(state) do
    session =
      state.session
      |> Map.put("state", "closed")
      |> Map.update!("revision", &(&1 + 1))

    %{state | closed: true, session: session}
  end

  defp awaiting_turn(session_id, message, attempt \\ 1) do
    sha256 = :crypto.hash(:sha256, message) |> Base.encode16(case: :lower)

    %{
      "candidate" => %{"attempt" => attempt, "message" => message, "sha256" => sha256},
      "id" => "turn_test",
      "session_id" => session_id,
      "state" => "awaiting_validation"
    }
  end

  defp resumed_turn(candidates, true) do
    [candidate | remaining] = candidates
    {awaiting_turn("remote_test", candidate), remaining}
  end

  defp resumed_turn(candidates, false), do: {nil, candidates}

  defp operation_for_key(state, key, calls) do
    state = prepare_resumed_resource(state, key)

    cond do
      Map.has_key?(state.known_operations, key) ->
        {{:ok, state.known_operations[key]}, state}

      state.fail_first_operation and is_nil(state.failed_operation_key) ->
        operation = failed_operation(operation_method(key))

        {{:ok, operation},
         %{
           state
           | failed_operation_key: key,
             known_operations: Map.put(state.known_operations, key, operation)
         }}

      state.resume_operations ->
        {operation(key, state.operation_mode, calls), state}

      true ->
        {:not_found, state}
    end
  end

  defp successful_turn_submission(state, session_id, key, schema) do
    [candidate | remaining] = state.candidates
    current = session_id |> awaiting_turn(candidate) |> override_turn_identity(state)
    queued = %{current | "state" => "queued", "candidate" => nil}
    operation = succeeded_operation("SubmitTurn", "turn", current["id"])

    next = %{
      state
      | candidates: remaining,
        known_operations: Map.put(state.known_operations, key, operation),
        schema: schema,
        session: Map.update!(state.session, "revision", &(&1 + 1)),
        submit_count: state.submit_count + 1,
        turn: current
    }

    response =
      if state.async_submit,
        do: %{"operation" => maybe_running_operation(operation, state.async_operations_running)},
        else: %{"turn" => queued}

    {{:ok, response}, next}
  end

  defp accept_candidate(state, key, sha256) do
    message = state.accepted_candidate_override || state.turn["candidate"]["message"]
    attempt = state.turn["candidate"]["attempt"]
    completed_sha256 = :crypto.hash(:sha256, message) |> Base.encode16(case: :lower)

    completed =
      state.turn
      |> Map.put("assistant_message", message)
      |> Map.put("candidate", nil)
      |> Map.put("state", "completed")
      |> Map.put("validation_attempt", attempt)
      |> Map.put("validation_candidate_sha256", completed_sha256)
      |> Map.put("validation_receipt", "validation_test")
      |> maybe_omit_validation_digest(state.omit_validation_digest)
      |> maybe_omit_validation_receipt(state.omit_validation_receipt)

    validation = %{sha256: sha256, verdict: :accept, violations: []}

    session =
      state.session
      |> Map.update!("revision", &(&1 + 1))
      |> maybe_exhaust(state.exhaust_after_validation)
      |> maybe_close_after_validation(state.close_after_validation)

    response = %{"turn" => completed}

    next = %{
      state
      | session: session,
        turn: completed,
        validation_responses: Map.put(state.validation_responses, key, response),
        validations: state.validations ++ [validation]
    }

    {{:ok, response}, next}
  end

  defp failed_operation(method) do
    %{
      "error_code" => "repository_unavailable",
      "error_detail" => "temporary workspace preparation failure",
      "id" => "op_failed",
      "method" => method,
      "state" => "failed"
    }
  end

  defp fence_operation(agent, key, method) do
    Agent.get_and_update(agent, fn state ->
      operation =
        Map.get(state.known_operations, key) ||
          %{
            "error_code" => "operation_fenced",
            "error_detail" => "operation was fenced before execution",
            "id" => "op_fenced",
            "method" => method,
            "state" => "failed"
          }

      {{:ok, operation},
       %{state | known_operations: Map.put(state.known_operations, key, operation)}}
    end)
  end

  defp failed_turn(session_id, state) do
    %{
      "error_code" => if(state == "failed", do: "provider_unavailable", else: state),
      "error_detail" => "simulated terminal turn state",
      "id" => "turn_failed",
      "session_id" => session_id,
      "state" => state
    }
  end

  defp succeeded_operation(method, resource_type, resource_id) do
    %{
      "id" => "op_#{resource_type}",
      "method" => method,
      "resource_id" => resource_id,
      "resource_type" => resource_type,
      "state" => "succeeded"
    }
  end

  defp maybe_running_operation(operation, true), do: Map.put(operation, "state", "running")
  defp maybe_running_operation(operation, false), do: operation

  defp maybe_omit_validation_digest(turn, true),
    do: Map.delete(turn, "validation_candidate_sha256")

  defp maybe_omit_validation_digest(turn, false), do: turn

  defp maybe_omit_validation_receipt(turn, true), do: Map.delete(turn, "validation_receipt")
  defp maybe_omit_validation_receipt(turn, false), do: turn

  defp maybe_close_after_validation(session, true), do: Map.put(session, "state", "closed")
  defp maybe_close_after_validation(session, false), do: session

  defp maybe_exhaust(session, true), do: Map.put(session, "state", "exhausted")
  defp maybe_exhaust(session, false), do: session

  defp override_turn_identity(turn, state) do
    turn
    |> maybe_put("id", state.turn_id_override)
    |> maybe_put("session_id", state.turn_session_id_override)
  end

  defp maybe_put(document, _field, nil), do: document
  defp maybe_put(document, field, value), do: Map.put(document, field, value)

  defp operation(key, :pending_once, 1) do
    {:ok, %{"id" => "op_pending", "method" => operation_method(key), "state" => "reserved"}}
  end

  defp operation(key, :failed, _calls) do
    {:ok, failed_operation(operation_method(key))}
  end

  defp operation(key, _mode, _calls) do
    {resource_type, resource_id} =
      if String.contains?(key, ":create:"),
        do: {"session", "remote_test"},
        else: {"turn", "turn_test"}

    {:ok, succeeded_operation(operation_method(key), resource_type, resource_id)}
  end

  defp operation_method(key) do
    if String.contains?(key, ":create:"), do: "CreateRemoteSession", else: "SubmitTurn"
  end

  defp prepare_resumed_resource(%{resume_operations: true} = state, key) do
    if String.contains?(key, ":create:") do
      external_ref =
        String.replace_prefix(
          key,
          "responder:admission:create:",
          "responder-admission:"
        )

      session =
        Map.merge(state.session, %{
          "external_ref" => external_ref,
          "policy" => "admission-read-only",
          "state" => "open"
        })

      %{state | session: session}
    else
      state
    end
  end

  defp prepare_resumed_resource(state, _key), do: state
end
