defmodule Ryker.TestSupport.FakeCoopAPI do
  @moduledoc false

  import Ryker.TestHelpers, only: [digest: 1]

  @behaviour Ryker.Coop.API

  alias Ryker.Evals.Job
  alias Ryker.Fixtures.WorkerJob

  # Each fake mints its own session and turn ids. One fixed "remote_test" session and
  # "turn_test" turn for every fake let no test catch two turns sharing an id (2026-10-04
  # review).
  def start_link(candidates, options \\ []) do
    resume_operations = Keyword.get(options, :resume_operations, false)
    session_id = "remote_#{System.unique_integer([:positive])}"
    {turn, candidates} = resumed_turn(candidates, session_id, resume_operations)

    Agent.start_link(fn ->
      %{
        async_create: Keyword.get(options, :async_create, false),
        # Ready-session creates still running on the worker: key => {operation, checks left}.
        pending_operations: %{},
        async_operations_running: Keyword.get(options, :async_operations_running, false),
        async_submit: Keyword.get(options, :async_submit, false),
        candidates: candidates,
        accepted_candidate_override: Keyword.get(options, :accepted_candidate_override),
        close_after_validation: Keyword.get(options, :close_after_validation, false),
        close_keys: [],
        closed: false,
        # Session ids in the order they were closed.
        closed_sessions: [],
        discard_keys: [],
        discard_plan_keys: [],
        discarded: false,
        create_keys: [],
        create_sources: [],
        exhaust_after_validation: Keyword.get(options, :exhaust_after_validation, false),
        fail_create: Keyword.get(options, :fail_create, false),
        first_create_error: Keyword.get(options, :first_create_error),
        fail_first_close: Keyword.get(options, :fail_first_close, false),
        failed_close_key: nil,
        fail_first_operation: Keyword.get(options, :fail_first_operation, false),
        failed_operation_key: nil,
        fail_first_turn: Keyword.get(options, :fail_first_turn, false),
        fail_first_turn_response: Keyword.get(options, :fail_first_turn_response, false),
        first_turn_state: Keyword.get(options, :first_turn_state, "failed"),
        # Every submitted turn ends in this terminal state, not only the first.
        every_turn_state: Keyword.get(options, :every_turn_state),
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
        # Prepares sent to the worker, by key, and each one's answer: the
        # fleet answers a repeated key from its record without asking again.
        prepare_keys: [],
        prepare_results: %{},
        # `:first` refuses the first prepare, `:always` every one.
        fail_prepare: Keyword.get(options, :fail_prepare, false),
        # Sessions whose agent Coop started ahead of their first turn.
        prepared_sessions: [],
        # A worker with other work refuses a prepare before sending it.
        worker_busy: Keyword.get(options, :worker_busy, false),
        # Sessions whose turn arrived on an agent already running.
        warm_turn_sessions: [],
        resume_operations: resume_operations,
        schema: nil,
        # Routing sessions kept ready, by id, beside the one session routing
        # creates for itself.
        sessions: %{},
        session: %{
          "external_ref" => nil,
          "id" => session_id,
          "project_env" => Keyword.get(options, :project_env, false),
          "project_mcp" => Keyword.get(options, :project_mcp, false),
          "repository_read_only" => Keyword.get(options, :repository_read_only, true),
          "revision" => 1,
          "state" => "open"
        },
        submit_count: 0,
        turn_id_override: Keyword.get(options, :turn_id_override),
        turn_report: Keyword.get(options, :turn_report, %{}),
        turn_session_id_override: Keyword.get(options, :turn_session_id_override),
        turn_keys: [],
        # The session each submitted turn ran on, in order.
        turn_sessions: [],
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
  def worker_idle(agent), do: Agent.update(agent, &%{&1 | worker_busy: false})

  @doc "Every session this Coop started, by id: routing's own and those kept ready."
  def sessions(agent) do
    Agent.get(agent, fn state -> Map.put(state.sessions, state.session["id"], state.session) end)
  end

  @impl true
  def operation_by_key(agent, key) do
    receipt =
      if Agent.get(agent, & &1.resume_operations) and
           String.starts_with?(key, "ryker:admission:create:"),
         do:
           job_receipt(String.replace_prefix(key, "ryker:admission:create:", "ryker-admission:")),
         else: %{}

    Agent.get_and_update(agent, fn state ->
      session = with_job(state.session, receipt)

      turn =
        if map_size(receipt) > 0 and state.turn,
          do: Map.put(state.turn, "session_id", session["id"]),
          else: state.turn

      state = %{state | session: session, turn: turn}
      calls = Map.update(state.operation_calls, key, 1, &(&1 + 1))
      state = %{state | operation_calls: calls}

      operation_for_key(state, key, calls[key])
    end)
  end

  @impl true
  def prepare_create_session(_agent, _key, _policy, task, _source) do
    job_receipt(task)
    :ok
  end

  defp job_receipt(task) do
    if String.starts_with?(task, [
         "ryker-admission:",
         "ryker-admission-ready:",
         "ryker-improvement:",
         "ryker-knowledge:",
         "ryker-learning:",
         "ryker-work:"
       ]),
       do: task |> WorkerJob.for_task!() |> WorkerJob.receipt(),
       else: %{}
  end

  defp with_job(session, receipt) when map_size(receipt) > 0,
    do:
      session
      |> Map.merge(receipt)
      |> Map.put("id", "remote:" <> receipt["job_ref"])

  defp with_job(session, _receipt), do: session

  @impl true
  def create_session(agent, key, %{} = template, task, nil) do
    {:ok, job, digest} = Job.bind(template, task)
    receipt = %{"job_ref" => job["job_ref"], "job_digest" => digest}
    create_routing_session(agent, key, nil, task, nil, receipt)
  end

  def create_session(agent, key, policy, task, source) do
    receipt = job_receipt(task)

    if String.starts_with?(key, "ryker:admission-ready:"),
      do: create_ready_session(agent, key, policy, task, source, receipt),
      else: create_routing_session(agent, key, policy, task, source, receipt)
  end

  # A session kept ready is a separate Coop session with its own identity.
  defp create_ready_session(agent, key, _policy, task, source, receipt) do
    Agent.get_and_update(agent, fn state ->
      id = "ready_#{map_size(state.sessions) + 1}"

      session =
        Map.merge(state.session, %{
          "external_ref" => task,
          "id" => id,
          "revision" => 1,
          "state" => "open"
        })
        |> with_job(receipt)
        |> Map.put("id", id)

      state = %{
        state
        | create_keys: state.create_keys ++ [key],
          create_sources: state.create_sources ++ [source]
      }

      operation = succeeded_operation("CreateRemoteSession", "session", id)

      cond do
        state.fail_create ->
          {{:error, {:coop_unavailable, :simulated}}, state}

        # Like the fleet: the create is accepted and the worker finishes it
        # a moment later, so the first answer is an operation still running.
        state.async_create ->
          {{:ok, %{"operation" => Map.put(operation, "state", "running")}},
           %{
             state
             | pending_operations: Map.put(state.pending_operations, key, {operation, 2}),
               sessions: Map.put(state.sessions, id, session)
           }}

        true ->
          {{:ok, %{"session" => session}},
           %{
             state
             | known_operations: Map.put(state.known_operations, key, operation),
               sessions: Map.put(state.sessions, id, session)
           }}
      end
    end)
  end

  defp create_routing_session(agent, key, _policy, task, source, receipt) do
    Agent.get_and_update(agent, fn state ->
      session =
        Map.merge(state.session, %{
          "external_ref" => task,
          "state" => "open"
        })
        |> with_job(receipt)

      response =
        cond do
          state.fail_create ->
            {:error, {:coop_unavailable, :simulated}}

          state.first_create_error != nil ->
            {:error, state.first_create_error}

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
        if state.fail_create or state.first_create_error != nil,
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
           create_sources: state.create_sources ++ [source],
           first_create_error: nil,
           known_operations: operations,
           session: session
       }}
    end)
  end

  @impl true
  def fence_create_session(agent, key, _policy, _task, _source),
    do: fence_operation(agent, key, "CreateRemoteSession")

  @impl true
  def get_session(agent, session_id),
    do: {:ok, Agent.get(agent, &session_for(&1, session_id))}

  @impl true
  def submit_turn(agent, session_id, key, _revision, prompt, schema) do
    Agent.get_and_update(agent, fn state ->
      warm_turn_sessions =
        if session_id in state.prepared_sessions,
          do: state.warm_turn_sessions ++ [session_id],
          else: state.warm_turn_sessions

      state =
        state
        |> Map.put(:submitted_prompt, prompt)
        |> Map.put(:turn_keys, state.turn_keys ++ [key])
        |> Map.put(:turn_sessions, state.turn_sessions ++ [session_id])
        |> Map.put(:warm_turn_sessions, warm_turn_sessions)

      terminal_state =
        cond do
          state.every_turn_state != nil -> state.every_turn_state
          state.fail_first_turn and is_nil(state.failed_turn_key) -> state.first_turn_state
          true -> nil
        end

      if terminal_state do
        failed = decorate_turn(failed_turn(session_id, terminal_state), state)

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
  def fence_frozen_turn(agent, _session_id, key, _revision, _submission, _binding, _artifacts),
    do: fence_operation(agent, key, "SubmitTurn")

  # Like the fleet: a key already sent is answered from its record, a busy
  # worker is not asked at all, and Coop answers with the session.
  @impl true
  def prepare_session(agent, session_id, key) do
    Agent.get_and_update(agent, fn state ->
      cond do
        Map.has_key?(state.prepare_results, key) -> {state.prepare_results[key], state}
        state.worker_busy -> {{:error, :coop_worker_busy}, state}
        true -> send_prepare(state, session_id, key)
      end
    end)
  end

  defp send_prepare(state, session_id, key) do
    refused? =
      state.fail_prepare == :always or
        (state.fail_prepare == :first and state.prepare_keys == [])

    {result, prepared} =
      if refused?,
        do:
          {{:error, {:coop_error, 503, "acp_process_error", "the agent did not start"}},
           state.prepared_sessions},
        else: {{:ok, session_for(state, session_id)}, state.prepared_sessions ++ [session_id]}

    {result,
     %{
       state
       | prepare_keys: state.prepare_keys ++ [key],
         prepare_results: Map.put(state.prepare_results, key, result),
         prepared_sessions: prepared
     }}
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
  def get_output_artifact(_agent, _session_id, _turn_id, _artifact_id),
    do: {:error, {:coop_error, 404, "artifact_not_found", "artifact not found"}}

  @impl true
  def cancel_turn(agent, _session_id, _turn_id, _key, _expected_revision) do
    Agent.get_and_update(agent, fn state ->
      cancelled =
        (state.turn ||
           decorate_turn(%{"id" => turn_id(), "session_id" => state.session["id"]}, state))
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
            |> awaiting_turn(state.turn["id"], candidate, attempt)
            |> decorate_turn(state)

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
  def close_session(agent, session_id, key, _revision) do
    Agent.get_and_update(agent, fn state ->
      state = %{state | close_keys: state.close_keys ++ [key]}

      cond do
        state.fail_first_close and is_nil(state.failed_close_key) ->
          closed = close_state(state, session_id)

          {{:error, {:coop_unavailable, :simulated_close_response_loss}},
           %{closed | failed_close_key: key}}

        state.failed_close_key == key ->
          {{:ok, %{"session" => session_for(state, session_id)}}, state}

        true ->
          closed = close_state(state, session_id)
          {{:ok, %{"session" => session_for(closed, session_id)}}, closed}
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

  defp close_state(state, session_id) do
    state
    |> update_session(session_id, fn session ->
      session
      |> Map.put("state", "closed")
      |> Map.update!("revision", &(&1 + 1))
    end)
    |> Map.merge(%{closed: true, closed_sessions: state.closed_sessions ++ [session_id]})
  end

  defp session_for(state, session_id), do: Map.get(state.sessions, session_id, state.session)

  defp update_session(state, session_id, update) do
    if Map.has_key?(state.sessions, session_id),
      do: %{state | sessions: Map.update!(state.sessions, session_id, update)},
      else: %{state | session: update.(state.session)}
  end

  defp turn_id, do: "turn_#{System.unique_integer([:positive])}"

  defp awaiting_turn(session_id, id, message, attempt \\ 1) do
    sha256 = digest(message)

    %{
      "candidate" => %{"attempt" => attempt, "message" => message, "sha256" => sha256},
      "id" => id,
      "session_id" => session_id,
      "state" => "awaiting_validation"
    }
  end

  defp resumed_turn(candidates, session_id, true) do
    [candidate | remaining] = candidates
    {awaiting_turn(session_id, turn_id(), candidate), remaining}
  end

  defp resumed_turn(candidates, _session_id, false), do: {nil, candidates}

  defp operation_for_key(state, key, calls) do
    state = prepare_resumed_resource(state, key)

    cond do
      Map.has_key?(state.known_operations, key) ->
        {{:ok, state.known_operations[key]}, state}

      Map.has_key?(state.pending_operations, key) ->
        case Map.fetch!(state.pending_operations, key) do
          {operation, 0} ->
            {{:ok, operation},
             %{
               state
               | pending_operations: Map.delete(state.pending_operations, key),
                 known_operations: Map.put(state.known_operations, key, operation)
             }}

          {operation, left} ->
            {{:ok, Map.put(operation, "state", "running")},
             %{
               state
               | pending_operations: Map.put(state.pending_operations, key, {operation, left - 1})
             }}
        end

      state.fail_first_operation and is_nil(state.failed_operation_key) ->
        operation = failed_operation(operation_method(key))

        {{:ok, operation},
         %{
           state
           | failed_operation_key: key,
             known_operations: Map.put(state.known_operations, key, operation)
         }}

      state.resume_operations ->
        {operation(key, state.operation_mode, calls, state), state}

      true ->
        {:not_found, state}
    end
  end

  defp successful_turn_submission(state, session_id, key, schema) do
    [candidate | remaining] = state.candidates
    current = session_id |> awaiting_turn(turn_id(), candidate) |> decorate_turn(state)
    queued = %{current | "state" => "queued", "candidate" => nil}
    operation = succeeded_operation("SubmitTurn", "turn", current["id"])

    next =
      %{
        state
        | candidates: remaining,
          known_operations: Map.put(state.known_operations, key, operation),
          schema: schema,
          submit_count: state.submit_count + 1,
          turn: current
      }
      |> update_session(session_id, &Map.update!(&1, "revision", fn revision -> revision + 1 end))

    response =
      if state.async_submit,
        do: %{"operation" => maybe_running_operation(operation, state.async_operations_running)},
        else: %{"turn" => queued}

    {{:ok, response}, next}
  end

  defp accept_candidate(state, key, sha256) do
    message = state.accepted_candidate_override || state.turn["candidate"]["message"]
    attempt = state.turn["candidate"]["attempt"]
    completed_sha256 = digest(message)

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
    response = %{"turn" => completed}

    next =
      %{
        state
        | turn: completed,
          validation_responses: Map.put(state.validation_responses, key, response),
          validations: state.validations ++ [validation]
      }
      |> update_session(state.turn["session_id"], fn session ->
        session
        |> Map.update!("revision", &(&1 + 1))
        |> maybe_exhaust(state.exhaust_after_validation)
        |> maybe_close_after_validation(state.close_after_validation)
      end)

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
            "id" => "op_fenced_#{System.unique_integer([:positive])}",
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

  defp decorate_turn(turn, state) do
    state.turn_report
    |> Map.merge(turn)
    |> maybe_put("id", state.turn_id_override)
    |> maybe_put("session_id", state.turn_session_id_override)
  end

  defp maybe_put(document, _field, nil), do: document
  defp maybe_put(document, field, value), do: Map.put(document, field, value)

  defp operation(key, :pending_once, 1, _state) do
    {:ok, %{"id" => "op_pending", "method" => operation_method(key), "state" => "reserved"}}
  end

  defp operation(key, :failed, _calls, _state) do
    {:ok, failed_operation(operation_method(key))}
  end

  defp operation(key, _mode, _calls, state) do
    {resource_type, resource_id} =
      if String.contains?(key, ":create:"),
        do: {"session", state.session["id"]},
        else: {"turn", (state.turn || %{"id" => turn_id()})["id"]}

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
          "ryker:admission:create:",
          "ryker-admission:"
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
