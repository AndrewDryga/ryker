defmodule Responder.TestSupport.FakeWorkCoopAPI do
  @moduledoc false

  @behaviour Responder.Coop.API

  alias Responder.Work.StateBinding

  def start_link(candidates, options \\ []) do
    Agent.start_link(fn ->
      %{
        candidates: candidates,
        activity_error: Keyword.get(options, :activity_error),
        activity_events: Keyword.get(options, :activity_events, []),
        activity_requests: [],
        bindings: [],
        cancel_keys: [],
        changes: Keyword.get(options, :changes, []),
        changes_count: 0,
        changes_page_requests: [],
        checkpoint_keys: [],
        checkpoint_error: nil,
        # Inspection evidence is optional on the wire. `nil` is a worker whose
        # daemon does not serve it at all; the other values are the ways a
        # capture fails once it does, and none of them may reach the turn.
        session_evidence: Keyword.get(options, :session_evidence),
        session_evidence_reads: 0,
        create_count: 0,
        create_keys: [],
        create_sources: [],
        fence_create_keys: [],
        fence_create_sources: [],
        fence_submit_keys: [],
        known_operations: %{},
        lose_first_cancel_response: Keyword.get(options, :lose_first_cancel_response, false),
        lose_first_submit_response: Keyword.get(options, :lose_first_submit_response, false),
        lose_first_validation_response:
          Keyword.get(options, :lose_first_validation_response, false),
        lost_cancel_response: false,
        lost_submit_response: false,
        lost_validation_response: false,
        output_artifact_metadata: Keyword.get(options, :output_artifact_metadata, []),
        output_artifacts: Keyword.get(options, :output_artifacts, %{}),
        on_validation_reject: Keyword.get(options, :on_validation_reject),
        pause_after_submit: Keyword.get(options, :pause_after_submit),
        paused_after_submit: false,
        turn_finished_at: Keyword.get(options, :turn_finished_at),
        turn_queued_at: Keyword.get(options, :turn_queued_at),
        turn_started_at: Keyword.get(options, :turn_started_at),
        turn_usage: Keyword.get(options, :turn_usage),
        operation_calls: %{},
        session: %{
          "base_commit" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
          "authority_digest" => Keyword.get(options, :authority_digest),
          "companions" => Keyword.get(options, :companions, []),
          "external_ref" => nil,
          "id" => "remote_work",
          "policy" => nil,
          "policy_digest" => String.duplicate("a", 64),
          "project_env" => Keyword.get(options, :project_env, false),
          "project_mcp" => Keyword.get(options, :project_mcp, false),
          "repository_read_only" => is_nil(Keyword.get(options, :workspace_task)),
          "workspace_task" => Keyword.get(options, :workspace_task),
          "repository_freshness" => freshness_receipts(options),
          "repository_freshness_status" => "recorded",
          "source" => default_source_binding(),
          "revision" => 1,
          "state" => "open",
          "target" => Keyword.get(options, :session_target, "codex:gpt-5.6-sol/high@work")
        },
        submissions: [],
        submit_count: 0,
        submit_error_count: 0,
        submit_errors: Keyword.get(options, :submit_errors, []),
        turn: nil,
        turn_keys: [],
        validation_keys: [],
        validations: []
      }
    end)
  end

  # The fake policy resolves its own configured default, as every new
  # repository-backed session does when nobody selected another source.
  defp default_source_binding do
    %{
      "admitted_tree" => "3f0b9f1d5a7e2c4b6d8a0c2e4f6a8b0c2d4e6f80",
      "base_commit" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
      "default_commit" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
      "default_ref" => "refs/heads/main",
      "kind" => "default",
      "remote_identity" => "local",
      "requested" => %{"kind" => "default"},
      "resolved_at" => "2026-09-04T08:00:00Z",
      "selected_commit" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
      "selected_ref" => "refs/heads/main",
      "version" => 1
    }
  end

  defp freshness_receipts(options) do
    primary = %{
      "fetched_at" => "2026-09-04T08:00:00Z",
      "name" => "primary",
      "remote_identity" => "local",
      "requested_revision" => "HEAD",
      "resolved_revision" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f",
      "stale_base_status" => "not_applicable",
      "version" => 2,
      "workspace_base_revision" => "5d1fa43d2efe46e8409dde0e93e79af93fb6622f"
    }

    companions =
      options
      |> Keyword.get(:companions, [])
      |> Enum.map(fn companion ->
        %{
          "fetched_at" => "2026-09-04T08:00:00Z",
          "name" => companion["name"],
          "remote_identity" => "local",
          "requested_revision" => "HEAD",
          "resolved_revision" => companion["base_commit"],
          "stale_base_status" => "not_applicable",
          "version" => 2
        }
      end)

    [primary | companions]
  end

  def state(agent), do: Agent.get(agent, & &1)

  @impl true
  def capabilities(_agent),
    do:
      {:ok,
       %{
         "repository_freshness_receipt_versions" => [2],
         "repository_source_selector_versions" => [1]
       }}

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
  def create_session(agent, key, policy, task, source) do
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
          create_sources: state.create_sources ++ [source],
          known_operations: Map.put(state.known_operations, key, operation),
          session: session
      }

      {{:ok, response}, next}
    end)
  end

  @impl true
  def fence_create_session(agent, key, _policy, _task, source) do
    Agent.update(agent, fn state ->
      %{state | fence_create_sources: state.fence_create_sources ++ [source]}
    end)

    fence_operation(agent, key, "CreateRemoteSession", :fence_create_keys)
  end

  @impl true
  def get_session(agent, _session_id), do: {:ok, Agent.get(agent, & &1.session)}

  @impl true
  def get_session_evidence(agent, _session_id) do
    Agent.get_and_update(agent, fn state ->
      {state.session_evidence,
       %{state | session_evidence_reads: state.session_evidence_reads + 1}}
    end)
    |> case do
      nil -> {:error, {:coop_error, 404, "not_found", "evidence export is unavailable"}}
      :raise -> raise "the evidence export blew up"
      :exit -> exit(:evidence_transport_died)
      {:error, _reason} = error -> error
      document when is_map(document) -> {:ok, document}
    end
  end

  @impl true
  def checkpoint_workspace(agent, _session_id, key, _expected_revision) do
    Agent.get_and_update(agent, fn state ->
      receipt = %{
        "checkpoint_ref" => "checkpoint:#{String.duplicate("c", 32)}",
        "state" => "stored",
        "transfer_id" => Ecto.UUID.generate()
      }

      result =
        if state.checkpoint_error, do: {:error, state.checkpoint_error}, else: {:ok, receipt}

      {result, %{state | checkpoint_keys: state.checkpoint_keys ++ [key]}}
    end)
  end

  @impl true
  def get_changes(agent, _session_id) do
    Agent.get_and_update(agent, fn state ->
      case state.changes do
        [changes, next | remaining] ->
          {{:ok, changes},
           %{state | changes: [next | remaining], changes_count: state.changes_count + 1}}

        [changes] ->
          {{:ok, changes}, %{state | changes_count: state.changes_count + 1}}

        [] ->
          {{:error, {:coop_error, 404, "workspace_not_found", "no workspace changes fixture"}},
           %{state | changes_count: state.changes_count + 1}}
      end
    end)
  end

  @impl true
  def get_changes_page(agent, session_id, patch_offset, patch_limit) do
    Agent.update(agent, fn state ->
      update_in(
        state,
        [:changes_page_requests],
        &(&1 ++ [{session_id, patch_offset, patch_limit}])
      )
    end)

    get_changes(agent, session_id)
  end

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
    submit_turn_with_artifacts(agent, session_id, key, expected_revision, prompt, schema, [])
  end

  @impl true
  def submit_turn_with_artifacts(
        agent,
        session_id,
        key,
        expected_revision,
        prompt,
        schema,
        artifacts
      ) do
    submit_with_binding(
      agent,
      session_id,
      key,
      expected_revision,
      prompt,
      schema,
      nil,
      artifacts
    )
  end

  @impl true
  def submit_frozen_turn(
        agent,
        session_id,
        key,
        expected_revision,
        submission,
        binding,
        artifacts
      ) do
    submit_with_binding(
      agent,
      session_id,
      key,
      expected_revision,
      submission["prompt"],
      submission["output_schema"],
      binding,
      artifacts
    )
  end

  defp submit_with_binding(
         agent,
         session_id,
         key,
         expected_revision,
         prompt,
         schema,
         binding,
         artifacts
       ) do
    result =
      Agent.get_and_update(agent, fn state ->
        submit_result(
          state,
          session_id,
          key,
          expected_revision,
          prompt,
          schema,
          binding,
          artifacts
        )
      end)

    pause_after_submit(agent, result)
  end

  defp pause_after_submit(agent, {:ok, _response} = result) do
    notify =
      Agent.get_and_update(agent, fn state ->
        if is_pid(state.pause_after_submit) and not state.paused_after_submit do
          {state.pause_after_submit, %{state | paused_after_submit: true}}
        else
          {nil, state}
        end
      end)

    if is_pid(notify) do
      send(notify, {:fake_work_submit_committed, self()})

      receive do
        {:release_fake_work_submit, caller} when caller == self() -> result
      end
    else
      result
    end
  end

  defp pause_after_submit(_agent, result), do: result

  defp submit_result(
         %{submit_errors: [error | remaining]} = state,
         _session_id,
         _key,
         _expected_revision,
         _prompt,
         _schema,
         _binding,
         _artifacts
       ) do
    {error,
     %{
       state
       | submit_error_count: state.submit_error_count + 1,
         submit_errors: remaining
     }}
  end

  defp submit_result(
         state,
         session_id,
         key,
         expected_revision,
         prompt,
         schema,
         binding,
         artifacts
       ) do
    [candidate | remaining] = state.candidates

    turn =
      session_id
      |> awaiting_turn("work_turn_#{session_id}_#{state.submit_count + 1}", candidate, 1)
      |> Map.put("output_artifacts", state.output_artifact_metadata)
      |> maybe_put_binding_digest(binding)

    operation = succeeded_operation("SubmitTurn", "turn", turn["id"])

    submission = %{
      expected_revision: expected_revision,
      artifacts: artifacts,
      responder_binding: binding,
      key: key,
      prompt: prompt,
      schema: schema
    }

    next = %{
      state
      | candidates: remaining,
        bindings: if(binding, do: state.bindings ++ [binding], else: state.bindings),
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
  end

  @impl true
  def fence_submit_turn(agent, _session_id, key, _expected_revision, _prompt, _schema) do
    fence_operation(agent, key, "SubmitTurn", :fence_submit_keys)
  end

  @impl true
  def fence_submit_turn_with_artifacts(
        agent,
        _session_id,
        key,
        _expected_revision,
        _prompt,
        _schema,
        _artifacts
      ) do
    fence_operation(agent, key, "SubmitTurn", :fence_submit_keys)
  end

  @impl true
  def fence_frozen_turn(
        agent,
        _session_id,
        key,
        _expected_revision,
        _submission,
        binding,
        _artifacts
      ) do
    Agent.update(agent, fn state ->
      %{state | bindings: if(binding, do: state.bindings ++ [binding], else: state.bindings)}
    end)

    fence_operation(agent, key, "SubmitTurn", :fence_submit_keys)
  end

  @impl true
  def get_turn(agent, _session_id, _turn_id), do: {:ok, Agent.get(agent, & &1.turn)}

  @impl true
  def list_events(agent, session_id, after_sequence, limit) do
    result =
      Agent.get_and_update(agent, fn state ->
        events =
          state.activity_events
          |> Enum.filter(&(&1["session_id"] == session_id and &1["sequence"] > after_sequence))
          |> Enum.sort_by(& &1["sequence"])
          |> Enum.take(limit)

        {if(state.activity_error, do: {:error, state.activity_error}, else: {:ok, events}),
         %{
           state
           | activity_requests: state.activity_requests ++ [{session_id, after_sequence, limit}]
         }}
      end)

    result
  end

  @impl true
  def get_output_artifact(agent, _session_id, _turn_id, artifact_id) do
    Agent.get(agent, fn state ->
      case Map.fetch(state.output_artifacts, artifact_id) do
        {:ok, artifact} -> {:ok, artifact}
        :error -> {:error, {:coop_error, 404, "artifact_not_found", "artifact not found"}}
      end
    end)
  end

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
        |> maybe_put("queued_at", state.turn_queued_at)
        |> maybe_put("started_at", state.turn_started_at)
        |> maybe_put("finished_at", state.turn_finished_at)
        |> maybe_put("usage", state.turn_usage)

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
    {response, on_validation_reject} =
      Agent.get_and_update(agent, fn state ->
        [candidate | remaining] = state.candidates
        attempt = state.turn["candidate"]["attempt"] + 1

        current =
          session_id
          |> awaiting_turn(turn_id, candidate, attempt)
          |> Map.put("output_artifacts", Map.get(state.turn, "output_artifacts", []))
          |> maybe_put("responder_binding_digest", state.turn["responder_binding_digest"])

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

        {{{:ok, %{"operation" => operation, "turn" => current}}, state.on_validation_reject},
         next}
      end)

    cond do
      is_function(on_validation_reject, 1) -> on_validation_reject.(violations)
      is_function(on_validation_reject, 0) -> on_validation_reject.()
      true -> :ok
    end

    response
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

  defp maybe_put_binding_digest(turn, nil), do: turn

  defp maybe_put_binding_digest(turn, binding) do
    token_sha256 = StateBinding.sha256(binding["token"])

    Map.put(
      turn,
      "responder_binding_digest",
      StateBinding.sha256(binding["endpoint"] <> <<0>> <> token_sha256)
    )
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
