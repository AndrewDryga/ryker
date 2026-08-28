defmodule Responder.TestSupport.FakeWorkCoopAPI do
  @moduledoc false

  @behaviour Responder.Coop.API

  def start_link(candidates, options \\ []) do
    Agent.start_link(fn ->
      %{
        candidates: candidates,
        cancel_keys: [],
        create_count: 0,
        create_keys: [],
        fence_create_keys: [],
        fence_submit_keys: [],
        known_operations: %{},
        lose_first_cancel_response: Keyword.get(options, :lose_first_cancel_response, false),
        lose_first_submit_response: Keyword.get(options, :lose_first_submit_response, false),
        lose_first_validation_response:
          Keyword.get(options, :lose_first_validation_response, false),
        lost_cancel_response: false,
        lost_submit_response: false,
        lost_validation_response: false,
        operation_calls: %{},
        session: %{
          "external_ref" => nil,
          "id" => "remote_work",
          "policy" => nil,
          "policy_digest" => String.duplicate("a", 64),
          "revision" => 1,
          "state" => "open"
        },
        submissions: [],
        submit_count: 0,
        turn: nil,
        turn_keys: [],
        validation_keys: [],
        validations: []
      }
    end)
  end

  def state(agent), do: Agent.get(agent, & &1)

  def update(agent, function) when is_function(function, 1),
    do: Agent.update(agent, function)

  def seed_operation(agent, key, operation) do
    Agent.update(agent, fn state ->
      %{state | known_operations: Map.put(state.known_operations, key, operation)}
    end)
  end

  def seed_turn(agent, session_id, turn_id, state \\ "running") do
    Agent.update(agent, fn current ->
      session = %{current.session | "id" => session_id, "revision" => 2}

      turn = %{
        "candidate" => nil,
        "id" => turn_id,
        "session_id" => session_id,
        "state" => state
      }

      %{current | session: session, turn: turn}
    end)
  end

  @impl true
  def operation_by_key(agent, key) do
    Agent.get_and_update(agent, fn state ->
      calls = Map.update(state.operation_calls, key, 1, &(&1 + 1))
      result = Map.fetch(state.known_operations, key)
      response = if match?({:ok, _operation}, result), do: result, else: :not_found
      {response, %{state | operation_calls: calls}}
    end)
  end

  @impl true
  def create_session(agent, key, policy, task) do
    Agent.get_and_update(agent, fn state ->
      session_id =
        if state.session["state"] in ~w(exhausted closed discarded),
          do: "#{state.session["id"]}:replacement:#{state.create_count + 1}",
          else: state.session["id"]

      session =
        Map.merge(state.session, %{
          "external_ref" => task,
          "id" => session_id,
          "policy" => policy,
          "revision" => 1,
          "state" => "open"
        })

      operation = succeeded_operation("CreateRemoteSession", "session", session["id"])

      response = %{
        "operation" => operation,
        "session" => session
      }

      next = %{
        state
        | create_count: state.create_count + 1,
          create_keys: state.create_keys ++ [key],
          known_operations: Map.put(state.known_operations, key, operation),
          session: session
      }

      {{:ok, response}, next}
    end)
  end

  @impl true
  def fence_create_session(agent, key, _policy, _task) do
    fence_operation(agent, key, "CreateRemoteSession", :fence_create_keys)
  end

  @impl true
  def get_session(agent, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

  @impl true
  def close_session(agent, _session_id, key, _expected_revision) do
    Agent.get_and_update(agent, fn state ->
      session =
        state.session
        |> Map.put("state", "closed")
        |> Map.update!("revision", &(&1 + 1))

      operation = succeeded_operation("CloseSession", "session", session["id"])
      response = %{"operation" => operation, "session" => session}

      {{:ok, response},
       %{
         state
         | known_operations: Map.put(state.known_operations, key, operation),
           session: session
       }}
    end)
  end

  @impl true
  def submit_turn(agent, session_id, key, expected_revision, prompt, schema) do
    Agent.get_and_update(agent, fn state ->
      [candidate | remaining] = state.candidates
      turn = awaiting_turn(session_id, "work_turn_#{session_id}", candidate, 1)
      operation = succeeded_operation("SubmitTurn", "turn", turn["id"])

      submission = %{
        expected_revision: expected_revision,
        key: key,
        prompt: prompt,
        schema: schema
      }

      next = %{
        state
        | candidates: remaining,
          known_operations: Map.put(state.known_operations, key, operation),
          session: Map.update!(state.session, "revision", &(&1 + 1)),
          submissions: state.submissions ++ [submission],
          submit_count: state.submit_count + 1,
          turn: turn,
          turn_keys: state.turn_keys ++ [key]
      }

      if state.lose_first_submit_response and not state.lost_submit_response do
        {{:error, {:coop_unavailable, :simulated_submit_response_loss}},
         %{next | lost_submit_response: true}}
      else
        {{:ok, %{"operation" => operation, "turn" => turn}}, next}
      end
    end)
  end

  @impl true
  def fence_submit_turn(agent, _session_id, key, _expected_revision, _prompt, _schema) do
    fence_operation(agent, key, "SubmitTurn", :fence_submit_keys)
  end

  @impl true
  def get_turn(agent, _session_id, _turn_id), do: {:ok, Agent.get(agent, & &1.turn)}

  @impl true
  def validate_candidate(agent, _session_id, _turn_id, key, sha256, :accept) do
    Agent.get_and_update(agent, fn state ->
      candidate = state.turn["candidate"]
      message = candidate["message"]

      completed =
        state.turn
        |> Map.put("assistant_message", message)
        |> Map.put("candidate", nil)
        |> Map.put("state", "completed")
        |> Map.put("validation_attempt", candidate["attempt"])
        |> Map.put("validation_candidate_sha256", sha256)
        |> Map.put("validation_receipt", "validation:#{state.turn["id"]}:#{candidate["attempt"]}")

      operation =
        succeeded_operation("ValidateTurnCandidate", "turn_validation", completed["id"])

      validation = %{sha256: sha256, verdict: :accept, violations: []}

      next = %{
        state
        | known_operations: Map.put(state.known_operations, key, operation),
          session: Map.update!(state.session, "revision", &(&1 + 1)),
          turn: completed,
          validation_keys: state.validation_keys ++ [key],
          validations: state.validations ++ [validation]
      }

      if state.lose_first_validation_response and not state.lost_validation_response do
        {{:error, {:coop_unavailable, :simulated_validation_response_loss}},
         %{next | lost_validation_response: true}}
      else
        {{:ok, %{"operation" => operation, "turn" => completed}}, next}
      end
    end)
  end

  def validate_candidate(agent, session_id, turn_id, key, sha256, {:reject, violations}) do
    Agent.get_and_update(agent, fn state ->
      [candidate | remaining] = state.candidates
      attempt = state.turn["candidate"]["attempt"] + 1
      current = awaiting_turn(session_id, turn_id, candidate, attempt)

      operation =
        succeeded_operation("ValidateTurnCandidate", "turn_validation", current["id"])

      validation = %{sha256: sha256, verdict: :reject, violations: violations}

      next = %{
        state
        | candidates: remaining,
          known_operations: Map.put(state.known_operations, key, operation),
          session: Map.update!(state.session, "revision", &(&1 + 1)),
          turn: current,
          validation_keys: state.validation_keys ++ [key],
          validations: state.validations ++ [validation]
      }

      {{:ok, %{"operation" => operation, "turn" => current}}, next}
    end)
  end

  @impl true
  def cancel_turn(agent, _session_id, _turn_id, key, _expected_revision) do
    Agent.get_and_update(agent, fn state ->
      cancelled =
        state.turn
        |> Map.put("candidate", nil)
        |> Map.put("state", "cancelled")

      operation = succeeded_operation("CancelTurn", "turn", cancelled["id"])

      next = %{
        state
        | cancel_keys: state.cancel_keys ++ [key],
          known_operations: Map.put(state.known_operations, key, operation),
          session: Map.update!(state.session, "revision", &(&1 + 1)),
          turn: cancelled
      }

      if state.lose_first_cancel_response and not state.lost_cancel_response do
        {{:error, {:coop_unavailable, :simulated_cancel_response_loss}},
         %{next | lost_cancel_response: true}}
      else
        {{:ok, %{"operation" => operation, "turn" => cancelled}}, next}
      end
    end)
  end

  defp awaiting_turn(session_id, turn_id, message, attempt) do
    %{
      "candidate" => %{
        "attempt" => attempt,
        "message" => message,
        "sha256" => digest(message)
      },
      "id" => turn_id,
      "session_id" => session_id,
      "state" => "awaiting_validation"
    }
  end

  defp succeeded_operation(method, resource_type, resource_id) do
    %{
      "id" => "op_#{resource_type}_#{resource_id}",
      "method" => method,
      "resource_id" => resource_id,
      "resource_type" => resource_type,
      "state" => "succeeded"
    }
  end

  defp fence_operation(agent, key, method, field) do
    Agent.get_and_update(agent, fn state ->
      operation =
        Map.get(state.known_operations, key) ||
          %{
            "error_code" => "operation_fenced",
            "error_detail" => "operation was fenced before execution",
            "id" => "op_fenced_#{method}_#{map_size(state.known_operations) + 1}",
            "method" => method,
            "state" => "failed"
          }

      next =
        state
        |> Map.put(:known_operations, Map.put(state.known_operations, key, operation))
        |> Map.update!(field, &(&1 ++ [key]))

      {{:ok, operation}, next}
    end)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
