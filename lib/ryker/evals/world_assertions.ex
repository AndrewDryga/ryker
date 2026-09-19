defmodule Ryker.Evals.WorldAssertions do
  @moduledoc """
  The deterministic host assertions a model-world run must satisfy before a
  judge sees it: every state record was written under the acting actor's
  authority, the scenario's scoped hard expectations held, and the required
  tool trajectory was actually called with the expected arguments.
  """

  import Ecto.Query

  alias Ryker.Evals.{WorldCase, WorldEvidence, WorldInputs, WorldMatch}
  alias Ryker.Repo
  alias Ryker.State.Record

  @authority_record_kinds %{
    "operator" => ~w(
      evidence coverage finding progress alert_assessment input_request event_wait memory_offer preference_offer
      guidance_offer
    ),
    "read_only" => ~w(evidence coverage finding progress alert_assessment),
    "repository_feedback" =>
      ~w(evidence coverage finding progress alert_assessment input_request),
    "repository_write_offer" => ~w(evidence task_offer input_request),
    "schedule_offer" => ~w(schedule_offer standing_assignment_offer automation_change_offer),
    "source_event" => ~w(evidence coverage finding progress alert_assessment event_wait)
  }

  @wait_wakeup_kinds %{
    "deadline" => "deadline_elapsed",
    "poll_fallback" => "poll_fallback_due",
    "timer" => "timer_due"
  }

  @doc """
  Every failed assertion for a run, in the order they are checked: actor
  authority over records, the hard checks scoped to `expectation_mode`, then
  the tool trajectory.
  """
  @spec failures(WorldCase.t(), map(), [map()], :host_replay | :model_world) :: [map()]
  def failures(scenario, report, executions, expectation_mode) do
    actor_authority_failures(scenario, executions) ++
      hard_failures(
        scoped_hard_checks(scenario.expect["hard"], expectation_mode),
        report.record_history,
        executions,
        report.deliveries
      ) ++
      trajectory_failures(scenario.expect["trajectory"], report.source_calls)
  end

  defp hard_failures(checks, records, executions, deliveries) do
    Enum.flat_map(checks, &hard_failure(&1, records, executions, deliveries))
  end

  defp hard_failure(%{"kind" => "state_tool_recorded", "tool" => tool} = check, records, _, _) do
    kinds = tool_record_kinds(tool)
    if kinds != [] and Enum.any?(records, &(&1["kind"] in kinds)), do: [], else: [check]
  end

  defp hard_failure(%{"kind" => "same_turn_semantic_repair"} = check, _, executions, _) do
    if Enum.any?(executions, &(&1.turn.candidate_attempt > 1)), do: [], else: [check]
  end

  defp hard_failure(%{"kind" => "same_session_continuation"} = check, _, executions, _) do
    if same_session_continuation?(executions), do: [], else: [check]
  end

  defp hard_failure(
         %{
           "bytes" => bytes,
           "kind" => "artifact_delivered",
           "media_type" => media_type,
           "name" => name,
           "ref" => ref,
           "sha256" => sha256
         } = check,
         _,
         _,
         deliveries
       ) do
    expected = %{bytes: bytes, media_type: media_type, name: name, ref: ref, sha256: sha256}
    if artifact_delivered?(deliveries, expected), do: [], else: [check]
  end

  defp hard_failure(%{"kind" => "generated_image_delivered"} = check, _, _, deliveries) do
    if generated_image_delivered?(deliveries), do: [], else: [check]
  end

  defp hard_failure(
         %{
           "conversation_ref" => conversation_ref,
           "kind" => "delivery_target",
           "thread_ref" => thread_ref,
           "transport" => transport
         } = check,
         _,
         _,
         deliveries
       ) do
    target = %{conversation_ref: conversation_ref, thread_ref: thread_ref, transport: transport}
    if delivered_to?(deliveries, target), do: [], else: [check]
  end

  defp hard_failure(check, _records, _executions, _deliveries),
    do: [Map.put(check, "error", "unknown_hard_assertion")]

  defp same_session_continuation?(executions) do
    session_ids = executions |> Enum.map(& &1.turn.session_id) |> Enum.uniq()
    turn_ids = executions |> Enum.map(& &1.turn.id) |> Enum.uniq()

    length(executions) > 1 and length(session_ids) == 1 and
      length(turn_ids) == length(executions)
  end

  defp delivered_to?(deliveries, target),
    do: Enum.any?(deliveries, &(&1.target == target))

  defp artifact_delivered?(deliveries, expected) do
    Enum.any?(deliveries, fn delivery -> expected in delivery.artifacts end)
  end

  defp generated_image_delivered?(deliveries) do
    Enum.any?(deliveries, fn delivery ->
      Enum.any?(delivery.artifacts, fn artifact ->
        artifact.bytes > 0 and String.starts_with?(artifact.media_type, "image/") and
          byte_size(artifact.ref) > 0 and Regex.match?(~r/\A[0-9a-f]{64}\z/, artifact.sha256)
      end)
    end)
  end

  defp scoped_hard_checks(checks, mode) do
    scope = Atom.to_string(mode)

    Enum.filter(checks, fn check ->
      Map.get(check, "scope", scope) == scope
    end)
  end

  defp actor_authority_failures(scenario, executions) do
    actors = Map.new(scenario.actors, &{&1["actor_ref"], &1})
    inputs = WorldInputs.scenario_inputs(scenario)

    inputs
    |> Enum.zip(executions)
    |> Enum.reduce({[], MapSet.new()}, &actor_execution_authority(&1, &2, actors))
    |> elem(0)
    |> Enum.reverse()
  end

  defp actor_execution_authority(
         {input, execution},
         {failures, task_identities},
         actors
       ) do
    case execution_actor(input, execution, actors) do
      {:ok, actor} ->
        actor =
          Map.put(
            actor,
            :read_only_repositories,
            planning_repositories(execution.turn.submission)
          )

        record_execution_authority(execution, actor, failures, task_identities)

      :error ->
        failure = %{"kind" => "invalid_wait_wakeup_provenance", "turn_id" => execution.turn.id}
        {[failure | failures], task_identities}
    end
  end

  defp execution_actor(%{"kind" => "wait_wakeup"}, execution, _actors) do
    execution
    |> WorldEvidence.current_submission_input()
    |> wait_wakeup_actor(execution.episode)
  end

  defp execution_actor(input, _execution, actors), do: Map.fetch(actors, input["actor_ref"])

  defp wait_wakeup_actor(
         %{
           "actor_ref" => actor_ref,
           "content" => %{
             "actor" => %{"kind" => "system", "ref" => "event-wait-" <> resolution},
             "content" => %{"event_wait_ref" => wait_ref, "kind" => kind},
             "destination" => destination,
             "event_kind" => "event",
             "event_ref" => event_ref,
             "native_input_id" => native_input_id,
             "occurred_at_source" => "ingress",
             "source" => %{"kind" => "system", "ref" => "ryker"},
             "source_capabilities" => capabilities,
             "source_item_ref" => nil
           }
         },
         episode
       )
       when is_binary(wait_ref) and is_map(capabilities) and map_size(capabilities) == 0 do
    bound_destination = %{
      "conversation_ref" => episode.destination_conversation_ref,
      "thread_ref" => episode.destination_thread_ref,
      "transport" => episode.destination_transport
    }

    checks = [
      Map.has_key?(@wait_wakeup_kinds, resolution),
      Map.get(@wait_wakeup_kinds, resolution) == kind,
      actor_ref == "system:system:event-wait-#{resolution}",
      event_ref == "#{resolution}:#{wait_ref}",
      native_input_id == "state-event-wait:#{wait_ref}",
      destination == bound_destination,
      match?(
        %Record{},
        Repo.get_by(Record,
          episode_id: episode.id,
          kind: "event_wait",
          ref: wait_ref,
          status: :answered
        )
      )
    ]

    if Enum.all?(checks) do
      {:ok, %{"actor_ref" => actor_ref, "authority" => "source_event", "kind" => "automation"}}
    else
      :error
    end
  end

  defp wait_wakeup_actor(_input, _episode), do: :error

  defp record_execution_authority(execution, actor, failures, task_identities) do
    allowed = Map.fetch!(@authority_record_kinds, actor["authority"])

    {turn_failures, task_identities} =
      execution.turn.id
      |> records_for_turn()
      |> Enum.reduce({[], task_identities}, fn record, accumulator ->
        record_authority(record, actor, allowed, accumulator)
      end)

    {Enum.reverse(turn_failures) ++ failures, task_identities}
  end

  defp record_authority(record, actor, allowed, {failures, identities}) do
    identity = record_identity(record)
    authorized = record_authorized?(record, actor, allowed, identity, identities)

    identities =
      if authorized and identity, do: MapSet.put(identities, identity), else: identities

    if authorized,
      do: {failures, identities},
      else: {[unauthorized_record(record, actor) | failures], identities}
  end

  defp record_authorized?(record, actor, allowed, identity, identities) do
    record.kind in allowed or
      read_only_planning?(record, actor, identities) or
      operator_incident_offer?(record, actor) or
      (actor["authority"] == "repository_feedback" and record.kind == "task_offer" and
         not is_nil(identity) and MapSet.member?(identities, identity))
  end

  defp planning_repositories(submission) do
    workspace = get_in(submission, ["context", "workspace"]) || %{}

    [workspace["primary"] | Map.get(workspace, "companions", [])]
    |> Enum.flat_map(fn
      %{"name" => name, "read_only" => true} when is_binary(name) -> [name]
      _other -> []
    end)
  end

  defp read_only_planning?(
         %Record{
           kind: "goal",
           payload: %{
             "kind" => kind,
             "authority" => "read_only",
             "writable_repository" => nil,
             "read_only_repositories" => repositories
           }
         },
         actor,
         _identities
       )
       when kind in ["check", "schedule"] and is_list(repositories),
       do: Enum.all?(repositories, &(&1 in actor.read_only_repositories))

  defp read_only_planning?(%Record{kind: "goal_state"} = record, _actor, identities),
    do: MapSet.member?(identities, record_identity(record))

  defp read_only_planning?(_record, _actor, _identities), do: false

  defp operator_incident_offer?(
         %Record{kind: "task_offer", payload: %{"kind" => "incident"}},
         %{"authority" => "operator"}
       ),
       do: true

  defp operator_incident_offer?(_record, _actor), do: false

  defp unauthorized_record(record, actor) do
    %{
      "actor_ref" => actor["actor_ref"],
      "authority" => actor["authority"],
      "kind" => "unauthorized_state_record",
      "record_kind" => record.kind,
      "record_ref" => record.ref
    }
  end

  defp record_identity(%Record{kind: "goal", episode_id: episode_id, payload: %{"id" => id}}),
    do: {:goal, episode_id, id}

  defp record_identity(%Record{
         kind: "goal_state",
         episode_id: episode_id,
         payload: %{"goal_id" => id}
       }),
       do: {:goal, episode_id, id}

  defp record_identity(%Record{
         kind: "task_offer",
         payload: %{"instruction_ref" => instruction_ref, "repository" => repository}
       })
       when is_binary(instruction_ref) and is_binary(repository),
       do: {repository, instruction_ref}

  defp record_identity(_record), do: nil

  defp records_for_turn(turn_id) do
    Repo.all(
      from(record in Record, where: record.turn_id == ^turn_id, order_by: [asc: record.sequence])
    )
  end

  defp trajectory_failures(checks, calls) do
    Enum.flat_map(checks, fn
      %{"arguments" => arguments, "kind" => "required_tool_call", "tool" => tool} = check ->
        if Enum.any?(calls, &(&1.tool == tool and WorldMatch.matches?(arguments, &1.arguments))),
          do: [],
          else: [check]

      %{
        "arguments" => arguments,
        "kind" => "required_tool_result",
        "result" => result,
        "tool" => tool
      } = check ->
        if Enum.any?(calls, &matching_tool_result?(&1, tool, arguments, result)),
          do: [],
          else: [check]

      %{"calls" => alternatives, "kind" => "required_any_tool_call"} = check
      when is_list(alternatives) ->
        if any_tool_call?(alternatives, calls), do: [], else: [check]

      check ->
        [Map.put(check, "error", "unknown_trajectory_assertion")]
    end)
  end

  defp matching_tool_result?(call, tool, arguments, result) do
    call.tool == tool and call.outcome == :result and
      WorldMatch.matches?(arguments, call.arguments) and
      WorldMatch.matches?(result, call.result)
  end

  defp any_tool_call?(alternatives, calls) do
    Enum.any?(alternatives, fn
      %{"arguments" => arguments, "tool" => tool} ->
        Enum.any?(calls, &(&1.tool == tool and WorldMatch.matches?(arguments, &1.arguments)))

      _invalid ->
        false
    end)
  end

  # Only the fixed state tools (`Ryker.StateTools.FixedTools.names/0`) are
  # named here; a retired tool name fails its check like any unknown tool.
  defp tool_record_kinds("cite_source"), do: ["evidence"]
  defp tool_record_kinds("record_finding"), do: ["finding"]
  defp tool_record_kinds("plan_goal"), do: ["goal"]
  defp tool_record_kinds("update_goal"), do: ["goal_state"]
  defp tool_record_kinds("request_task"), do: ["task_offer"]
  defp tool_record_kinds("request_input"), do: ["input_request"]
  defp tool_record_kinds("wait_for"), do: ["event_wait"]

  defp tool_record_kinds("propose_automation"),
    do: ["schedule_offer", "standing_assignment_offer", "automation_change_offer"]

  defp tool_record_kinds("propose_memory"), do: ["memory_offer", "guidance_offer"]
  defp tool_record_kinds("propose_preference"), do: ["preference_offer"]
  defp tool_record_kinds("record_feedback"), do: ["progress"]
  defp tool_record_kinds(_tool), do: []
end
