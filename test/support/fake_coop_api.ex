defmodule Responder.TestSupport.FakeCoopAPI do
  @moduledoc false

  @behaviour Responder.Coop.API

  def start_link(candidates, options \\ []) do
    resume_operations = Keyword.get(options, :resume_operations, false)
    {turn, candidates} = resumed_turn(candidates, resume_operations)

    Agent.start_link(fn ->
      %{
        candidates: candidates,
        accepted_candidate_override: Keyword.get(options, :accepted_candidate_override),
        close_keys: [],
        closed: false,
        create_keys: [],
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
        session: %{"id" => "remote_test", "revision" => 1, "state" => "open"},
        submit_count: 0,
        turn_keys: [],
        turn: turn,
        turn_wait_polls: Keyword.get(options, :turn_wait_polls, 0),
        validation_keys: [],
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
  def create_session(agent, key, _policy, _task) do
    Agent.get_and_update(agent, fn state ->
      response =
        if state.fail_create,
          do: {:error, {:coop_unavailable, :simulated}},
          else: {:ok, %{"session" => state.session}}

      operations =
        if state.fail_create,
          do: state.known_operations,
          else:
            Map.put(
              state.known_operations,
              key,
              succeeded_operation("session", state.session["id"])
            )

      {response,
       %{
         state
         | create_keys: state.create_keys ++ [key],
           known_operations: operations
       }}
    end)
  end

  @impl true
  def get_session(agent, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

  @impl true
  def submit_turn(agent, session_id, key, _revision, _prompt, schema) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | turn_keys: state.turn_keys ++ [key]}

      if state.fail_first_turn and is_nil(state.failed_turn_key) do
        failed = failed_turn(session_id, state.first_turn_state)

        operation =
          succeeded_operation("turn", failed["id"])

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
  def validate_candidate(agent, _session_id, _turn_id, key, sha256, :accept) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | validation_keys: state.validation_keys ++ [key]}
      error = state.first_validation_error

      cond do
        state.fail_first_validation and is_nil(state.failed_validation_key) ->
          {{:error, error}, %{state | failed_validation_key: key}}

        state.fail_first_validation and state.failed_validation_key == key ->
          {{:error, error}, state}

        true ->
          accept_candidate(state, sha256)
      end
    end)
  end

  def validate_candidate(agent, session_id, _turn_id, _key, sha256, {:reject, violations}) do
    Agent.get_and_update(agent, fn state ->
      [candidate | remaining] = state.candidates
      current = awaiting_turn(session_id, candidate)
      validation = %{sha256: sha256, verdict: :reject, violations: violations}

      next = %{
        state
        | candidates: remaining,
          turn: current,
          validations: state.validations ++ [validation]
      }

      {{:ok, %{"turn" => current}}, next}
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

  defp close_state(state) do
    session =
      state.session
      |> Map.put("state", "closed")
      |> Map.update!("revision", &(&1 + 1))

    %{state | closed: true, session: session}
  end

  defp awaiting_turn(session_id, message) do
    sha256 = :crypto.hash(:sha256, message) |> Base.encode16(case: :lower)

    %{
      "candidate" => %{"message" => message, "sha256" => sha256},
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
    cond do
      Map.has_key?(state.known_operations, key) ->
        {{:ok, state.known_operations[key]}, state}

      state.fail_first_operation and is_nil(state.failed_operation_key) ->
        operation = failed_operation()

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
    current = awaiting_turn(session_id, candidate)
    queued = %{current | "state" => "queued", "candidate" => nil}
    operation = succeeded_operation("turn", current["id"])

    next = %{
      state
      | candidates: remaining,
        known_operations: Map.put(state.known_operations, key, operation),
        schema: schema,
        session: Map.update!(state.session, "revision", &(&1 + 1)),
        submit_count: state.submit_count + 1,
        turn: current
    }

    {{:ok, %{"turn" => queued}}, next}
  end

  defp accept_candidate(state, sha256) do
    message = state.accepted_candidate_override || state.turn["candidate"]["message"]
    completed_sha256 = :crypto.hash(:sha256, message) |> Base.encode16(case: :lower)

    completed =
      state.turn
      |> Map.put("assistant_message", message)
      |> Map.put("candidate", nil)
      |> Map.put("state", "completed")
      |> Map.put("validation_candidate_sha256", completed_sha256)
      |> Map.put("validation_receipt", "validation_test")
      |> maybe_omit_validation_digest(state.omit_validation_digest)
      |> maybe_omit_validation_receipt(state.omit_validation_receipt)

    validation = %{sha256: sha256, verdict: :accept, violations: []}

    next = %{
      state
      | session: Map.update!(state.session, "revision", &(&1 + 1)),
        turn: completed,
        validations: state.validations ++ [validation]
    }

    {{:ok, %{"turn" => completed}}, next}
  end

  defp failed_operation do
    %{
      "error_code" => "repository_unavailable",
      "error_detail" => "temporary workspace preparation failure",
      "id" => "op_failed",
      "state" => "failed"
    }
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

  defp succeeded_operation(resource_type, resource_id) do
    %{
      "id" => "op_#{resource_type}",
      "resource_id" => resource_id,
      "resource_type" => resource_type,
      "state" => "succeeded"
    }
  end

  defp maybe_omit_validation_digest(turn, true),
    do: Map.delete(turn, "validation_candidate_sha256")

  defp maybe_omit_validation_digest(turn, false), do: turn

  defp maybe_omit_validation_receipt(turn, true), do: Map.delete(turn, "validation_receipt")
  defp maybe_omit_validation_receipt(turn, false), do: turn

  defp operation(_key, :pending_once, 1) do
    {:ok, %{"id" => "op_pending", "state" => "reserved"}}
  end

  defp operation(_key, :failed, _calls) do
    {:ok, failed_operation()}
  end

  defp operation(key, _mode, _calls) do
    {resource_type, resource_id} =
      if String.contains?(key, ":create:"),
        do: {"session", "remote_test"},
        else: {"turn", "turn_test"}

    {:ok, succeeded_operation(resource_type, resource_id)}
  end
end
