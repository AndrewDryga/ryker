defmodule Ryker.Evals.WorldDriver do
  @moduledoc """
  Drives a scenario's inputs through the real host boundaries one at a time:
  admission, the Work claim and its remote turn, and delivery through the
  evaluation adapters. Scheduled wait wakeups resume the exact persisted event
  wait at its own due time instead of fabricating a new input.
  """

  alias Ryker.Admission
  alias Ryker.Admission.{Candidate, Context, Decision}
  alias Ryker.Delivery.Dispatcher
  alias Ryker.Episodes.Episode
  alias Ryker.Evals.{WorldCase, WorldInputs}
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.State.{EventSubscription, EventWaits, Record, Records}
  alias Ryker.Work.{Custody, Turn}
  alias Ryker.Work.Dispatcher, as: WorkDispatcher

  @doc """
  Executes every input in order and returns the executions alongside the
  wait-wakeup checkpoints skipped because the episode had already completed.
  """
  @spec execute_inputs([map()], WorldCase.t(), map(), map(), String.t(), DateTime.t()) ::
          {:ok, [map()], [map()]} | {:error, term()}
  def execute_inputs(inputs, scenario, settings, adapters, identity, world_started_at) do
    inputs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, [], nil, []}, fn {input, index},
                                                {:ok, executions, episode_id, skipped} ->
      result =
        if completed_wait_checkpoint?(input, executions) do
          {:skip,
           %{
             after_turn_id: hd(executions).turn.id,
             episode_id: episode_id,
             kind: input["kind"],
             reason: "episode_complete",
             scenario_index: index,
             scenario_occurred_at: input["occurred_at"]
           }}
        else
          execute_input(
            input,
            index,
            scenario,
            settings,
            adapters,
            episode_id,
            identity,
            world_started_at
          )
        end

      case result do
        {:skip, checkpoint} ->
          {:cont, {:ok, executions, episode_id, [checkpoint | skipped]}}

        {:ok, execution} ->
          {:cont, {:ok, [execution | executions], execution.episode.id, skipped}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, executions, _episode_id, skipped} ->
        {:ok, Enum.reverse(executions), Enum.reverse(skipped)}

      {:error, _reason} = error ->
        error
    end
  end

  defp completed_wait_checkpoint?(%{"kind" => "wait_wakeup"}, [execution | _]) do
    # Checkpoints offer bounded continuation; they cannot require the model to
    # create another wait after an accepted result has actually settled delivery.
    match?(
      %Episode{state: :complete, owner_kind: nil, owner_ref: nil, queued_input_refs: []},
      Repo.get(Episode, execution.episode.id)
    ) and match?(%Turn{status: :settled}, Repo.get(Turn, execution.turn.id))
  end

  defp completed_wait_checkpoint?(_input, _executions), do: false

  defp execute_input(
         %{"actor_ref" => actor_ref, "occurred_at" => _occurred_at, "payload" => %{} = payload} =
           input,
         index,
         scenario,
         settings,
         adapters,
         expected_episode_id,
         identity,
         world_started_at
       )
       when is_binary(actor_ref) and map_size(payload) > 0 do
    with {:ok, input} <-
           WorldInputs.world_input(input, index, scenario, identity, world_started_at, payload),
         true <- Input.actor_ref(input) == actor_ref or {:error, :input_actor},
         {:ok, admission} <-
           admit_world_input(input, index, scenario, settings, expected_episode_id),
         {:ok, claim} <- Custody.claim_next("#{settings.worker_ref}:work:#{index}", 300, :work),
         true <- not is_nil(claim) or {:error, :work_not_claimable},
         true <- claim.episode.id == admission.episode.id or {:error, :crossed_world_claim},
         :ok <- settings.before_execute.(claim, scenario),
         {:ok, execution} <- execute_work(claim, scenario, settings, index, 4),
         :ok <- accepted(execution),
         :ok <- deliver_message(execution, adapters, settings, index, 3) do
      {:ok, Map.put(execution, :world_routing, admission.routing)}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :input_event}}
    end
  end

  defp execute_input(
         %{"kind" => "wait_wakeup"},
         index,
         scenario,
         settings,
         adapters,
         episode_id,
         _identity,
         _world_started_at
       )
       when is_binary(episode_id) do
    with {:ok, episode} <- current_waiting_episode(episode_id),
         %Record{} = record <-
           Repo.get_by(Record,
             episode_id: episode.id,
             kind: "event_wait",
             ref: episode.owner_ref,
             status: :open
           ),
         {:ok, subscription} <- wait_subscription(episode, record),
         :ok <- settings.before_wait_wakeup.(episode, record),
         {:ok, episode} <- resume_wait_wakeup(episode, record, subscription.poll_after),
         {:ok, claim} <- Custody.claim_next("#{settings.worker_ref}:work:#{index}", 300, :work),
         true <- not is_nil(claim) or {:error, :work_not_claimable},
         true <- claim.episode.id == episode.id or {:error, :crossed_world_claim},
         :ok <- settings.before_execute.(claim, scenario),
         {:ok, execution} <- execute_work(claim, scenario, settings, index, 4),
         :ok <- accepted(execution),
         :ok <- deliver_message(execution, adapters, settings, index, 3) do
      {:ok,
       Map.put(execution, :world_routing, %{
         action: "continue_episode",
         mode: "forced_host_scenario",
         reason: "Resume the exact durable wait at its persisted wakeup time.",
         relation: "same_work"
       })}
    else
      nil -> {:error, {:world_eval_failed, :event_wait_not_found}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :wait_wakeup}}
    end
  end

  # Still reachable: `WorldInputs.input_events/1` admits a wait wakeup in
  # first position, where no episode exists yet for the clause above.
  defp execute_input(
         _input,
         _index,
         _scenario,
         _settings,
         _adapters,
         _episode_id,
         _identity,
         _world_started_at
       ),
       do: {:error, {:invalid_world_runner, :input_event}}

  defp admit_world_input(input, index, scenario, settings, expected_episode_id) do
    with {:ok, %{entry: entry}} <- Inbox.record(input),
         now <- Repo.now!(),
         {:ok, %{entry: claimed, lease_ref: lease_ref}} <-
           Inbox.claim_next("#{settings.worker_ref}:admission:#{index}", now, 300),
         true <- claimed.id == entry.id or {:error, :crossed_world_input_claim},
         {:ok, context} <-
           Admission.context(Inbox.ref(claimed),
             candidate_limit: 20,
             continuation_window: 30 * 24 * 60 * 60,
             history_window: 30 * 24 * 60 * 60,
             lease_ref: lease_ref,
             now: WorldInputs.max_datetime(input.occurred_at, now)
           ),
         {:ok, decision, waiting_event} <- world_decision(context, expected_episode_id, input),
         {:ok, result} <-
           Admission.commit(
             context,
             decision,
             "world-admission:#{scenario.id}:#{index}",
             lease_ref: lease_ref,
             work_policy: %{digest: settings.policy_digest, name: settings.policy}
           ),
         :ok <- ensure_world_wait_resumed(waiting_event, result.episode, input) do
      {:ok, %{episode: result.episode, routing: routing_evidence(decision)}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :admission}}
    end
  end

  defp world_decision(%Context{candidates: candidates}, nil, _input) when candidates == [] do
    {:ok,
     %Decision{
       action: :start_episode,
       episode_ref: nil,
       reaction: nil,
       relation: :unrelated,
       reason: "Start the scenario's first work episode.",
       repository_source: nil,
       work_class: :standard
     }, nil}
  end

  defp world_decision(%Context{} = context, expected_episode_id, input)
       when is_binary(expected_episode_id) do
    case Enum.find(context.candidates, &(&1.episode.id == expected_episode_id)) do
      %Candidate{} = candidate ->
        waiting_event =
          if candidate.episode.state == :waiting_for_event do
            %{
              matches?: Records.user_resumable_wait?(candidate.episode.owner_ref, input),
              ref: candidate.episode.owner_ref
            }
          end

        {:ok,
         %Decision{
           action: :continue_episode,
           episode_ref: candidate.ref,
           reaction: nil,
           relation: :same_work,
           reason: "Continue the scenario's existing work episode.",
           repository_source: nil,
           work_class: :standard
         }, waiting_event}

      nil ->
        {:error, {:world_eval_failed, {:episode_candidate_not_found, expected_episode_id}}}
    end
  end

  defp world_decision(_context, _expected_episode_id, _input),
    do: {:error, {:invalid_world_runner, :admission_context}}

  defp routing_evidence(%Decision{} = decision) do
    %{
      action: Atom.to_string(decision.action),
      mode: "forced_host_scenario",
      reason: decision.reason,
      relation: Atom.to_string(decision.relation)
    }
  end

  defp ensure_world_wait_resumed(nil, %Episode{}, _input), do: :ok

  defp ensure_world_wait_resumed(%{matches?: false, ref: wait_ref}, %Episode{} = episode, input) do
    if episode.state == :waiting_for_event and episode.owner_ref == wait_ref do
      {:error,
       {:world_eval_failed,
        {:event_wait_not_matched, wait_ref, input.event_ref, input.source.kind}}}
    else
      {:error, {:world_eval_failed, {:event_wait_mismatch_lost, wait_ref}}}
    end
  end

  defp ensure_world_wait_resumed(%{matches?: true, ref: wait_ref}, %Episode{} = episode, _input) do
    if episode.state == :waiting_for_event and episode.owner_ref == wait_ref,
      do: {:error, {:world_eval_failed, {:event_wait_not_resumed, wait_ref}}},
      else: :ok
  end

  defp current_waiting_episode(episode_id) do
    case Repo.get(Episode, episode_id) do
      %Episode{state: :waiting_for_event, owner_kind: :event} = episode -> {:ok, episode}
      %Episode{} -> {:error, {:world_eval_failed, :event_wait_not_open}}
      nil -> {:error, {:world_eval_failed, :episode_not_found}}
    end
  end

  defp wait_subscription(%Episode{} = episode, %Record{} = record) do
    case Repo.get_by(EventSubscription, episode_id: episode.id, record_id: record.id) do
      %EventSubscription{status: :active, poll_after: %DateTime{}} = subscription ->
        {:ok, subscription}

      %EventSubscription{status: status} ->
        {:error,
         {:world_eval_failed, {:wait_subscription_not_active, record.ref, Atom.to_string(status)}}}

      nil ->
        {:error, {:world_eval_failed, {:wait_subscription_not_found, record.ref}}}
    end
  end

  defp resume_wait_wakeup(episode, record, occurred_at) do
    # Snapshot time precedes fault injection. Production rechecks current custody;
    # a changed due time must not silently advance the simulator past the fault.
    case EventWaits.resume_at(record.id, episode.id, occurred_at) do
      {:ok, %{episode: resumed, record: %Record{status: :answered}}} ->
        {:ok, resumed}

      {:ok, :idle} ->
        {:error,
         {:world_eval_failed, {:wait_wakeup_rejected, record.ref, :event_wait_already_resumed}}}

      {:error, reason} ->
        {:error, {:world_eval_failed, {:wait_wakeup_rejected, record.ref, reason}}}
    end
  end

  defp accepted(%{status: :accepted, turn: %{status: :delivery_pending}}), do: :ok

  defp accepted(execution) do
    metadata = %{
      status: execution.status,
      turn_id: execution.turn.id,
      turn_status: execution.turn.status
    }

    {:error, {:world_eval_failed, {:work_not_accepted, metadata}}}
  end

  defp execute_work(claim, scenario, settings, index, left) do
    options = [
      executor_options: [
        api: settings.api,
        client: settings.client,
        require_project_isolation: true,
        require_repository_read_only: true,
        platform_tools: settings.source_and_action_tools,
        state_tools_endpoint: settings.state_tools_endpoint,
        state_tools_secret: settings.state_tools_secret,
        workspace_requirements: WorldCase.repository_requirements(scenario)
      ],
      lease_seconds: 300,
      max_attempts: 4,
      retry_base_seconds: 1,
      retry_max_seconds: 1,
      worker_ref: "#{settings.worker_ref}:work:#{index}:#{5 - left}"
    ]

    case WorkDispatcher.run_claim(claim, options) do
      {:ok, {:executed, execution}} ->
        {:ok, execution}

      {:ok, {:deferred, reason}} when left == 1 ->
        {:error, {:world_eval_failed, {:work_retry_exhausted, reason}}}

      {:ok, {:deferred, _reason}} ->
        make_work_claimable(claim.turn.id)

        with {:ok, retried} <-
               Custody.claim_next("#{settings.worker_ref}:work:#{index}:#{6 - left}", 300, :work),
             true <- not is_nil(retried) or {:error, :work_retry_not_claimable} do
          execute_work(retried, scenario, settings, index, left - 1)
        else
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error

      _unexpected ->
        {:error, {:world_eval_failed, :unexpected_work_result}}
    end
  end

  defp make_work_claimable(turn_id) do
    Repo.query!(
      "UPDATE episode_work_turns SET next_attempt_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(turn_id)]
    )

    :ok
  end

  defp deliver_message(_execution, _adapters, _settings, _index, 0),
    do: {:error, {:world_eval_failed, :delivery_retry_exhausted}}

  defp deliver_message(execution, adapters, settings, index, left) do
    case Dispatcher.run_once(
           adapters: adapters,
           kind: :message,
           lease_seconds: 60,
           max_attempts: 3,
           retry_base_seconds: 1,
           retry_max_seconds: 1,
           worker_ref: "#{settings.worker_ref}:delivery:#{index}:#{4 - left}"
         ) do
      {:ok, {:delivered, :message, _delivery_ref}} ->
        :ok

      {:ok, {:deferred, :message, _delivery_ref, _reason}} ->
        make_delivery_claimable(execution.turn.id)
        deliver_message(execution, adapters, settings, index, left - 1)

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:world_eval_failed, {:delivery_result, other}}}
    end
  end

  defp make_delivery_claimable(turn_id) do
    Repo.query!(
      "UPDATE episode_work_turns SET next_attempt_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [Ecto.UUID.dump!(turn_id)]
    )

    :ok
  end
end
