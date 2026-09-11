defmodule Responder.Evals.WorldRunner do
  @moduledoc """
  Runs one model-world scenario through the real episode, Work, state-record,
  validation, and delivery boundaries.

  The runner never contacts a platform publisher. Visible output is settled by
  an evaluation-only adapter, while Coop and the production Responder state
  tools remain real. Callers provide an isolated database and Coop policy.
  """

  import Ecto.Query

  alias Responder.Admission
  alias Responder.Admission.{Candidate, Context, Decision}
  alias Responder.Delivery.{Adapters, Dispatcher}
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}

  alias Responder.Evals.{
    Evidence,
    GitHubDeliveryPublisher,
    LabDeliveryPublisher,
    SlackDeliveryPublisher,
    WorldCase,
    WorldCassette,
    WorldMatch
  }

  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership
  alias Responder.State.{EventSubscription, EventWaits, Record, Records}
  alias Responder.Work.{Custody, Measurement, Turn}
  alias Responder.Work.Dispatcher, as: WorkDispatcher

  @fields [
    :api,
    :before_execute,
    :before_wait_wakeup,
    :cassette,
    :client,
    :cleanup,
    :cleanup_remote,
    :expectation_mode,
    :id_generator,
    :judge,
    :policy,
    :policy_digest,
    :source_and_action_tools,
    :state_tools_endpoint,
    :state_tools_secret,
    :tool_catalog_sha256,
    :tool_names,
    :worker_ref
  ]

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

  @spec run(WorldCase.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def run(%WorldCase{} = scenario, options) do
    with {:ok, settings} <- settings(options),
         {:ok, delivery_agent} <- Agent.start_link(fn -> delivery_state(scenario) end) do
      try do
        execute(scenario, settings, delivery_agent)
      after
        Agent.stop(delivery_agent)
      end
    end
  end

  def run(_scenario, _options), do: {:error, {:invalid_world_runner, :scenario}}

  defp execute(scenario, settings, delivery_agent) do
    with {:ok, inputs} <- input_events(scenario),
         :ok <- disposable_database(settings.cleanup),
         identity <- settings.id_generator.(),
         :ok <- reference(identity, :identity) do
      scenario
      |> execute_without_cleanup(inputs, identity, settings, delivery_agent)
      |> retain_failure_report(scenario, identity, settings, delivery_agent)
      |> finish_execution(settings)
    end
  end

  defp execute_without_cleanup(scenario, inputs, identity, settings, delivery_agent) do
    settings =
      if is_nil(settings.source_and_action_tools) do
        %{settings | source_and_action_tools: WorldCase.fabricated_tools(scenario)}
      else
        settings
      end

    world_started_at = database_now!()

    with {:ok, adapters} <- eval_adapters(delivery_agent),
         :ok <- join_scenario_channels(inputs, world_started_at),
         {:ok, executions, skipped} <-
           execute_inputs(
             inputs,
             scenario,
             settings,
             adapters,
             identity,
             world_started_at
           ),
         {:ok, report} <- assess(scenario, executions, delivery_agent, settings, skipped) do
      {:ok, report}
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:world_eval_runner_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:world_eval_runner_caught, kind, inspect(reason)}}
  end

  # Correlation only reaches conversations Responder has actually joined, so a
  # scenario that reports one incident in two channels has to declare that
  # membership. It is evaluation-world setup, not permission: the channels are
  # exactly the ones the scenario's own inputs arrive in, and every one of them
  # is an ordinary non-private, non-shared channel.
  defp join_scenario_channels(inputs, now) do
    inputs
    |> Enum.flat_map(&scenario_channel/1)
    |> Enum.uniq()
    |> Enum.each(fn {workspace_ref, channel_ref} ->
      Repo.insert!(
        %ChannelMembership{
          id: Ecto.UUID.generate(),
          workspace_ref: workspace_ref,
          channel_ref: channel_ref,
          private: false,
          external_shared: false,
          generation: 1,
          status: :joined,
          joined_at: now,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: :nothing,
        conflict_target: [:workspace_ref, :channel_ref]
      )
    end)

    :ok
  end

  defp scenario_channel(%{
         "kind" => "input",
         "destination" => %{"transport" => "slack", "conversation_ref" => reference}
       }) do
    case String.split(reference, ":", parts: 3) do
      ["slack", workspace_ref, "C" <> _ = channel_ref] -> [{workspace_ref, channel_ref}]
      _other -> []
    end
  end

  defp scenario_channel(_event), do: []

  defp finish_execution(result, %{cleanup: false}), do: result

  defp finish_execution(result, %{cleanup: true} = settings) do
    cleanup_result = run_cleanup(result, settings.cleanup_remote, fn -> maybe_cleanup(true) end)

    finish_result(result, cleanup_result)
  end

  @doc false
  @spec run_cleanup({:ok, map()} | {:error, term()}, (-> term()), (-> term())) ::
          :ok | {:error, term()}
  def run_cleanup(result, remote_cleanup, local_cleanup)
      when is_function(remote_cleanup, 0) and is_function(local_cleanup, 0) do
    # Failed runs are the fixtures we need next. A safe workcopy discard must
    # not erase the database containing the failure or unresolved cleanup custody.
    with :ok <- cleanup_call(remote_cleanup) do
      if match?({:ok, %{status: :passed}}, result),
        do: cleanup_call(local_cleanup),
        else: :ok
    end
  end

  @doc false
  @spec finish_result({:ok, map()} | {:error, term()}, :ok | {:error, term()}) ::
          {:ok, map()} | {:error, term()}
  def finish_result(result, :ok), do: result

  def finish_result({:error, {:world_eval_assertions, report}}, {:error, cleanup}) do
    cleanup_failure(report, cleanup)
  end

  def finish_result({:ok, report}, {:error, cleanup}) do
    cleanup_failure(report, cleanup)
  end

  defp cleanup_failure(report, cleanup) do
    report =
      report
      |> Map.put(:cleanup_error, cleanup)
      |> Map.put(:status, if(report.status == :unrun, do: :unrun, else: :failed))

    {:error, {:world_eval_assertions, report}}
  end

  defp retain_failure_report({:ok, _report} = result, _scenario, _identity, _settings, _agent),
    do: result

  defp retain_failure_report({:error, {:world_eval_assertions, _report}} = result, _, _, _, _),
    do: result

  defp retain_failure_report({:error, reason}, scenario, identity, settings, agent) do
    # Snapshot before cleanup can cancel the wait. Only turns with a remote turn
    # receipt count as model execution; preparation or failed authority checks do not.
    first_event_ref = "world-event:#{scenario.id}:#{identity}:1"

    executions =
      from(turn in Turn,
        join: input in Entry,
        on: input.episode_id == turn.episode_id and input.event_ref == ^first_event_ref,
        where: not is_nil(turn.coop_turn_id),
        order_by: [asc: turn.inserted_at, asc: turn.id],
        preload: [:episode, :session]
      )
      |> Repo.all()
      |> Enum.map(&%{turn: &1, episode: &1.episode, session: &1.session, world_routing: nil})

    scenario
    |> report_data(executions, agent, settings, [])
    |> execution_failure(reason)
  end

  defp execution_failure(report, reason) do
    report =
      report
      |> Map.put(:execution_error, reason)
      |> Map.put(:status, if(report.runtime.turns == [], do: :unrun, else: :failed))

    {:error, {:world_eval_assertions, report}}
  end

  @doc false
  @spec terminalize_waiting_episodes() :: :ok | {:error, term()}
  def terminalize_waiting_episodes do
    now = database_now!()

    Episode
    |> where([episode], episode.state in [:waiting_for_input, :waiting_for_event])
    |> order_by([episode], [episode.inserted_at, episode.id])
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn episode, :ok ->
      command = %Command.CancelEpisode{
        cancel_ref: "model-world-cleanup:#{episode.id}:v#{episode.semantic_version}",
        episode_key: episode.key,
        expected_owner: %{kind: episode.owner_kind, ref: episode.owner_ref},
        occurred_at: now,
        reason: "The disposable model-world observation finished."
      }

      case Episodes.apply(command) do
        {:ok, _transition} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:world_cleanup_cancel_failed, episode.id, reason}}}
      end
    end)
  end

  defp cleanup_call(callback) do
    case callback.() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      invalid -> {:error, invalid}
    end
  rescue
    error -> {:error, {:model_world_cleanup_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:model_world_cleanup_caught, kind, inspect(reason)}}
  end

  defp disposable_database(cleanup) do
    with :ok <- disposable_name(cleanup) do
      if Enum.all?(application_tables(), &table_empty?/1),
        do: :ok,
        else: {:error, :model_world_requires_an_empty_disposable_database}
    end
  end

  defp disposable_name(false), do: :ok

  defp disposable_name(true) do
    %{rows: [[database]]} = Repo.query!("SELECT current_database()")

    if String.starts_with?(database, "responder_world_eval_"),
      do: :ok,
      else: {:error, :model_world_database_not_disposable}
  end

  defp maybe_cleanup(true) do
    case application_tables() do
      [] ->
        :ok

      tables ->
        targets = Enum.map_join(tables, ", ", &quoted_identifier/1)

        case Repo.query("TRUNCATE TABLE #{targets} RESTART IDENTITY CASCADE") do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, {:model_world_cleanup_failed, reason}}
        end
    end
  end

  defp quoted_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")

  defp application_tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema()
        AND table_type = 'BASE TABLE'
        AND table_name <> 'schema_migrations'
      ORDER BY table_name
      """)

    Enum.map(rows, fn [table] -> table end)
  end

  defp table_empty?(table) when is_binary(table) do
    quoted = ~s("#{String.replace(table, "\"", "\"\"")}")
    %{rows: [[empty]]} = Repo.query!("SELECT NOT EXISTS (SELECT 1 FROM #{quoted} LIMIT 1)")
    empty
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp input_events(%WorldCase{actors: actors} = scenario) do
    inputs = scenario_inputs(scenario)
    actor_refs = MapSet.new(actors, & &1["actor_ref"])

    cond do
      inputs == [] ->
        {:error, {:invalid_world_runner, :initial_input}}

      not Enum.all?(inputs, &input_actor?(&1, actor_refs)) ->
        {:error, {:invalid_world_runner, :input_actor}}

      true ->
        {:ok, inputs}
    end
  end

  defp input_actor?(%{"kind" => "wait_wakeup", "occurred_at" => occurred_at} = event, _refs),
    do: map_size(event) == 2 and is_binary(occurred_at)

  defp input_actor?(%{"kind" => "input", "actor_ref" => actor_ref}, refs),
    do: MapSet.member?(refs, actor_ref)

  defp input_actor?(_event, _refs), do: false

  defp scenario_inputs(%WorldCase{} = scenario) do
    initial = Enum.filter(scenario.events, &(&1["kind"] == "input"))

    initial ++ scenario.world["scheduled_events"]
  end

  defp execute_inputs(inputs, scenario, settings, adapters, identity, world_started_at) do
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
           world_input(input, index, scenario, identity, world_started_at, payload),
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
      false -> {:error, {:world_eval_failed, :crossed_world_claim}}
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
      false -> {:error, {:world_eval_failed, :crossed_world_claim}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :wait_wakeup}}
    end
  end

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

  defp world_input(event, index, scenario, identity, world_started_at, content) do
    actor = Enum.find(scenario.actors, &(&1["actor_ref"] == event["actor_ref"]))

    with %{"input_profile" => profile} <- actor,
         {:ok, source_occurred_at, 0} <- DateTime.from_iso8601(event["occurred_at"]),
         {:ok, clock_started_at, 0} <- DateTime.from_iso8601(scenario.clock["start"]),
         rebased_at <-
           DateTime.add(
             world_started_at,
             DateTime.diff(source_occurred_at, clock_started_at, :microsecond),
             :microsecond
           ),
         occurred_at <- max_datetime(rebased_at, DateTime.add(database_now!(), 1, :microsecond)),
         {:ok, destination} <- input_destination(event),
         {:ok, actor_kind} <- input_atom(profile["actor"]["kind"], :actor_kind),
         {:ok, event_kind} <- input_atom(profile["event_kind"], :event_kind),
         {:ok, occurred_at_source} <-
           input_atom(profile["occurred_at_source"], :occurred_at_source),
         {:ok, content} <- world_replay_content(content, event, occurred_at, occurred_at_source) do
      Input.new(%{
        actor: %{kind: actor_kind, ref: profile["actor"]["ref"]},
        content: content,
        destination: destination,
        event_kind: event_kind,
        event_ref: "world-event:#{scenario.id}:#{identity}:#{index}",
        native_input_id: "world-input:#{scenario.id}:#{identity}:#{index}",
        occurred_at: occurred_at,
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: profile["source"]["kind"], ref: profile["source"]["ref"]},
        source_capabilities: profile["source_capabilities"],
        source_item_ref: source_item_ref(profile, event, source_occurred_at, scenario.id, index)
      })
    else
      nil -> {:error, {:invalid_world_runner, :input_actor}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :input_profile}}
    end
  end

  defp world_replay_content(content, event, received_at, occurred_at_source) do
    if Map.has_key?(content, "world_replay_clock") do
      {:error, {:invalid_world_runner, :reserved_input_metadata}}
    else
      clock = %{
        "host_received_at" => DateTime.to_iso8601(received_at),
        "mode" => "simulated",
        "note" =>
          "Only receipt timing is rebased to exercise live host waits. Use the original source time for event chronology. Original source content and tool observations retain their historical dates; this replay supplies no present-day health proof.",
        "scenario_occurred_at" => event["occurred_at"],
        "scenario_occurred_at_source" => Atom.to_string(occurred_at_source),
        "source_occurred_at" => if(occurred_at_source == :source, do: event["occurred_at"])
      }

      {:ok, Map.put(content, "world_replay_clock", clock)}
    end
  end

  defp source_item_ref(
         _profile,
         %{"source_item_ref" => source_item_ref},
         _occurred_at,
         _id,
         _index
       ),
       do: source_item_ref

  defp source_item_ref(
         %{"source_capabilities" => capabilities},
         _event,
         _occurred_at,
         _id,
         _index
       )
       when map_size(capabilities) == 0,
       do: nil

  defp source_item_ref(
         %{"source" => %{"kind" => "slack"}},
         _event,
         occurred_at,
         _id,
         _index
       ),
       do: slack_timestamp(occurred_at)

  defp source_item_ref(%{"source" => %{"kind" => "github"}}, _event, _occurred_at, _id, _index),
    do: nil

  defp source_item_ref(
         %{"source" => %{"kind" => "control_plane"}},
         _event,
         _occurred_at,
         scenario_id,
         index
       ),
       do: "control-plane-item:#{scenario_id}:#{index}"

  defp source_item_ref(_profile, _event, _occurred_at, scenario_id, index),
    do: "world-source-item:#{scenario_id}:#{index}"

  defp slack_timestamp(occurred_at) do
    microseconds = DateTime.to_unix(occurred_at, :microsecond)
    seconds = div(microseconds, 1_000_000)
    fraction = microseconds |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{fraction}"
  end

  defp input_atom("app", :actor_kind), do: {:ok, :app}
  defp input_atom("bot", :actor_kind), do: {:ok, :bot}
  defp input_atom("system", :actor_kind), do: {:ok, :system}
  defp input_atom("user", :actor_kind), do: {:ok, :user}
  defp input_atom("message", :event_kind), do: {:ok, :message}
  defp input_atom("edit", :event_kind), do: {:ok, :edit}
  defp input_atom("delete", :event_kind), do: {:ok, :delete}
  defp input_atom("event", :event_kind), do: {:ok, :event}
  defp input_atom("source", :occurred_at_source), do: {:ok, :source}
  defp input_atom("ingress", :occurred_at_source), do: {:ok, :ingress}
  defp input_atom(_value, field), do: {:error, {:invalid_world_runner, field}}

  defp admit_world_input(input, index, scenario, settings, expected_episode_id) do
    with {:ok, %{entry: entry}} <- Inbox.record(input),
         now <- database_now!(),
         {:ok, %{entry: claimed, lease_ref: lease_ref}} <-
           Inbox.claim_next("#{settings.worker_ref}:admission:#{index}", now, 300),
         true <- claimed.id == entry.id or {:error, :crossed_world_input_claim},
         {:ok, context} <-
           Admission.context(Inbox.ref(claimed),
             candidate_limit: 20,
             continuation_window: 30 * 24 * 60 * 60,
             history_window: 30 * 24 * 60 * 60,
             lease_ref: lease_ref,
             now: max_datetime(input.occurred_at, now)
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
      false -> {:error, {:world_eval_failed, :crossed_world_input_claim}}
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

  defp max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
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
          false -> {:error, {:world_eval_failed, :work_retry_not_claimable}}
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

  defp eval_adapters(agent) do
    Adapters.new(%{
      "control_plane" => %{
        binding: agent,
        message_publisher: LabDeliveryPublisher,
        reaction_publisher: LabDeliveryPublisher
      },
      "github" => %{
        binding: agent,
        message_publisher: GitHubDeliveryPublisher,
        reaction_publisher: GitHubDeliveryPublisher
      },
      "slack" => %{
        binding: agent,
        message_publisher: SlackDeliveryPublisher,
        reaction_publisher: SlackDeliveryPublisher
      }
    })
  end

  defp input_destination(%{
         "destination" => %{
           "conversation_ref" => conversation_ref,
           "thread_ref" => thread_ref,
           "transport" => transport
         }
       })
       when is_binary(conversation_ref) and (is_binary(thread_ref) or is_nil(thread_ref)) and
              transport in ~w(slack github control_plane) do
    {:ok, %{conversation_ref: conversation_ref, thread_ref: thread_ref, transport: transport}}
  end

  defp input_destination(%{"destination" => _invalid}),
    do: {:error, {:invalid_world_runner, :destination}}

  defp input_destination(_input), do: {:error, {:invalid_world_runner, :destination}}

  defp assess(scenario, executions, delivery_agent, settings, skipped) do
    report = report_data(scenario, executions, delivery_agent, settings, skipped)

    failures =
      actor_authority_failures(scenario, executions) ++
        hard_failures(
          scoped_hard_checks(scenario.expect["hard"], settings.expectation_mode),
          report.record_history,
          executions,
          report.deliveries
        ) ++
        trajectory_failures(scenario.expect["trajectory"], report.source_calls)

    report = %{report | failures: failures, status: if(failures == [], do: :unrun, else: :failed)}

    cond do
      failures != [] -> {:error, {:world_eval_assertions, report}}
      is_nil(settings.judge) -> {:ok, report}
      true -> apply_judgment(settings.judge.(scenario, report), report)
    end
  end

  defp report_data(scenario, executions, delivery_agent, settings, skipped) do
    execution = List.last(executions)
    episode_id = if execution, do: execution.episode.id

    %{
      deliveries: delivery_agent |> Agent.get(&delivery_attempts/1) |> Enum.map(&delivery/1),
      episode_id: episode_id,
      failures: [],
      quality: %{status: :unrun},
      record_history: if(episode_id, do: record_history(episode_id), else: []),
      records: if(episode_id, do: Records.retained_records(episode_id), else: []),
      runtime: runtime_evidence(scenario, executions, settings, skipped),
      scenario_id: scenario.id,
      source_calls: if(settings.cassette, do: WorldCassette.calls(settings.cassette), else: []),
      status: :unrun,
      turn_id: if(execution, do: execution.turn.id),
      turn_ids: Enum.map(executions, & &1.turn.id)
    }
  end

  defp record_history(episode_id) do
    Repo.all(
      from(record in Record,
        where: record.episode_id == ^episode_id,
        order_by: [asc: record.inserted_at, asc: record.id]
      )
    )
    |> Enum.map(fn record ->
      %{
        "kind" => record.kind,
        "payload" => record.payload,
        "ref" => record.ref,
        "status" => Atom.to_string(record.status),
        "turn_id" => record.turn_id
      }
    end)
  end

  defp runtime_evidence(scenario, executions, settings, skipped) do
    %{
      policy: settings.policy,
      policy_digest: settings.policy_digest,
      skipped_checkpoints: skipped,
      tool_catalog_sha256: settings.tool_catalog_sha256 || scenario.tool_catalog_digest,
      tool_names: settings.tool_names || catalog_tool_names(scenario.tool_catalog),
      turns:
        executions
        |> Enum.zip(scenario_inputs(scenario))
        |> Enum.map(&runtime_turn_evidence/1)
    }
  end

  defp runtime_turn_evidence({execution, event}) do
    input = current_submission_input(execution)
    envelope = Map.fetch!(input, "content")

    execution
    |> turn_evidence()
    |> Map.put(:input_clock, %{
      adjustment: input_clock_adjustment(event, envelope),
      applied_occurred_at: Map.fetch!(input, "occurred_at"),
      mode: "simulated",
      scenario_occurred_at: event["occurred_at"],
      source_occurred_at:
        get_in(envelope, ["content", "world_replay_clock", "source_occurred_at"])
    })
    |> Map.put(:input_provenance, %{
      actor: Map.fetch!(envelope, "actor"),
      actor_ref: Map.fetch!(input, "actor_ref"),
      destination: Map.fetch!(envelope, "destination"),
      event_kind: Map.fetch!(envelope, "event_kind"),
      source: Map.fetch!(envelope, "source"),
      source_capabilities: Map.fetch!(envelope, "source_capabilities"),
      source_item_ref: Map.fetch!(envelope, "source_item_ref"),
      source_ref: Map.fetch!(input, "source_ref")
    })
    |> Map.put(:routing, execution.world_routing)
  end

  defp input_clock_adjustment(%{"kind" => "wait_wakeup"}, _envelope),
    do: "persisted_wait_due_at"

  defp input_clock_adjustment(_event, _envelope), do: "causal_rebase"

  defp current_submission_input(%{turn: %{submission: %{"context" => context}}}) do
    context |> current_submission_inputs() |> List.last()
  end

  defp current_submission_inputs(%{"mode" => "full", "inputs" => %{"items" => items}}),
    do: items

  defp current_submission_inputs(%{
         "mode" => "continuation",
         "current_inputs" => %{"items" => items}
       }),
       do: items

  defp turn_evidence(%{turn: turn}) do
    target = Measurement.target_parts(turn.execution_target)

    %{
      cached_input_tokens: turn.usage_cached_input_tokens,
      candidate: candidate_evidence(turn.candidate),
      candidate_attempt: turn.candidate_attempt,
      candidate_sha256: turn.candidate_sha256,
      cost_recorded: turn.usage_cost_recorded,
      cost_usd: decimal_string(turn.usage_cost_usd),
      effort: target.effort,
      host_ms: turn.usage_host_ms,
      input_tokens: turn.usage_input_tokens,
      model: target.model,
      output_tokens: turn.usage_output_tokens,
      prompt_sha256: prompt_sha256(turn.submission),
      provider: target.provider,
      provider_ms: turn.usage_provider_ms,
      queued_ms: turn.usage_queued_ms,
      reasoning_tokens: turn.usage_reasoning_tokens,
      repair_count: max((turn.candidate_attempt || 1) - 1, 0),
      session_id: turn.session_id,
      turn_id: turn.id,
      validation: validation_evidence(turn)
    }
  end

  defp candidate_evidence(candidate) when is_binary(candidate) do
    case Jason.decode(candidate) do
      {:ok, document} -> Evidence.sanitize(document, 64 * 1_024)
      _invalid -> %{"sha256" => sha256(candidate), "unparseable" => true}
    end
  end

  defp candidate_evidence(_candidate), do: nil

  defp validation_evidence(turn) do
    %{
      intent_sha256: turn.validation_intent_fingerprint,
      receipt_sha256: optional_sha256(turn.validation_receipt),
      verdict: get_in(turn.validation_intent || %{}, ["verdict"])
    }
  end

  defp optional_sha256(value) when is_binary(value), do: sha256(value)
  defp optional_sha256(_value), do: nil

  defp catalog_tool_names(%{"servers" => servers}) do
    for %{"tools" => tools} <- servers, %{"name" => name} <- tools, do: name
  end

  defp prompt_sha256(%{"prompt" => prompt}) when is_binary(prompt) do
    :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
  end

  defp prompt_sha256(_submission), do: nil

  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(nil), do: nil

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp apply_judgment({:ok, %{decision: decision, status: status} = judgment}, report)
       when status in [:passed, :failed] do
    {:ok,
     %{
       report
       | quality: %{
           decision: decision,
           reason: Map.get(judgment, :reason),
           status: status
         },
         status: status
     }}
  end

  defp apply_judgment({:error, reason}, report),
    do: execution_failure(report, {:world_eval_judge, reason})

  defp apply_judgment(other, report),
    do: execution_failure(report, {:world_eval_judge, {:invalid_result, other}})

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
    inputs = scenario_inputs(scenario)

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
    execution |> current_submission_input() |> wait_wakeup_actor(execution.episode)
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
             "source" => %{"kind" => "system", "ref" => "responder"},
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

  defp delivery(%{attempts: attempts, kind: kind, receipt: receipt, request: request}) do
    %{
      artifacts: Enum.map(request.artifacts, &delivery_artifact/1),
      attempts: attempts,
      document: request.document,
      kind: kind,
      receipt: receipt,
      target: %{
        conversation_ref: request.conversation_ref,
        thread_ref: request.thread_ref,
        transport: request.transport
      }
    }
  end

  defp delivery({kind, request, receipt}) do
    delivery(%{attempts: 1, kind: kind, receipt: receipt, request: request})
  end

  defp delivery_artifact(artifact) do
    %{
      bytes: artifact["bytes"],
      media_type: artifact["media_type"],
      name: artifact["name"],
      ref: artifact["ref"],
      sha256: artifact["sha256"]
    }
  end

  defp tool_record_kinds("record_evidence"), do: ["evidence"]
  defp tool_record_kinds("cite_source"), do: ["evidence"]
  defp tool_record_kinds("record_coverage"), do: ["coverage"]
  defp tool_record_kinds("record_finding"), do: ["finding"]
  defp tool_record_kinds("report_progress"), do: ["progress"]
  defp tool_record_kinds("plan_goal"), do: ["goal"]
  defp tool_record_kinds("update_goal"), do: ["goal_state"]
  defp tool_record_kinds("record_alert_assessment"), do: ["alert_assessment"]
  defp tool_record_kinds("offer_task"), do: ["task_offer"]
  defp tool_record_kinds("request_task"), do: ["task_offer"]
  defp tool_record_kinds("request_input"), do: ["input_request"]
  defp tool_record_kinds("wait_for"), do: ["event_wait"]

  defp tool_record_kinds("propose_automation"),
    do: ["schedule_offer", "standing_assignment_offer", "automation_change_offer"]

  defp tool_record_kinds("propose_memory"), do: ["memory_offer", "guidance_offer"]
  defp tool_record_kinds("record_feedback"), do: ["progress"]
  defp tool_record_kinds(_tool), do: []

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> settings(),
      else: {:error, {:invalid_world_runner, :options}}
  end

  defp settings(%{} = options) do
    if Map.keys(options) -- @fields == [] do
      options |> prepare_settings() |> validate_settings()
    else
      {:error, {:invalid_world_runner, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_world_runner, :options}}

  defp prepare_settings(options) do
    %{
      api: Map.get(options, :api, Responder.Coop.Client),
      before_execute: Map.get(options, :before_execute, fn _claim, _scenario -> :ok end),
      before_wait_wakeup: Map.get(options, :before_wait_wakeup, fn _episode, _record -> :ok end),
      cassette: Map.get(options, :cassette),
      client: Map.get(options, :client),
      cleanup: Map.get(options, :cleanup, false),
      cleanup_remote: Map.get(options, :cleanup_remote, fn -> :ok end),
      expectation_mode: Map.get(options, :expectation_mode, :host_replay),
      id_generator: Map.get(options, :id_generator, &Ecto.UUID.generate/0),
      judge: Map.get(options, :judge),
      policy: Map.get(options, :policy),
      policy_digest: Map.get(options, :policy_digest),
      source_and_action_tools: Map.get(options, :source_and_action_tools),
      state_tools_endpoint: Map.get(options, :state_tools_endpoint),
      state_tools_secret: Map.get(options, :state_tools_secret),
      tool_catalog_sha256: Map.get(options, :tool_catalog_sha256),
      tool_names: Map.get(options, :tool_names),
      worker_ref: Map.get(options, :worker_ref, "world-eval")
    }
  end

  defp validate_settings(settings) do
    checks = [
      is_atom(settings.api),
      not is_nil(settings.client),
      is_function(settings.before_execute, 2),
      is_function(settings.before_wait_wakeup, 2),
      is_boolean(settings.cleanup),
      is_function(settings.cleanup_remote, 0),
      settings.expectation_mode in [:host_replay, :model_world],
      is_function(settings.id_generator, 0),
      is_nil(settings.judge) or is_function(settings.judge, 2),
      reference(settings.policy, :policy) == :ok,
      digest?(settings.policy_digest),
      is_nil(settings.source_and_action_tools) or
        valid_source_and_action_tools?(settings.source_and_action_tools),
      reference(settings.state_tools_endpoint, :state_tools_endpoint) == :ok,
      reference(settings.state_tools_secret, :state_tools_secret) == :ok,
      is_nil(settings.tool_catalog_sha256) or digest?(settings.tool_catalog_sha256),
      is_nil(settings.tool_names) or valid_tool_names?(settings.tool_names),
      reference(settings.worker_ref, :worker_ref) == :ok
    ]

    if Enum.all?(checks),
      do: {:ok, settings},
      else: {:error, {:invalid_world_runner, :options}}
  end

  defp reference(value, _field) when is_binary(value) and byte_size(value) in 1..2_048 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, :reference}
  end

  defp reference(_value, field), do: {:error, field}

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp valid_tool_names?(names) when is_list(names),
    do: names == Enum.uniq(names) and Enum.all?(names, &(reference(&1, :tool_name) == :ok))

  defp valid_tool_names?(_names), do: false

  defp valid_source_and_action_tools?(tools) when is_list(tools) do
    names =
      Enum.map(tools, fn
        %{"name" => name} when is_binary(name) -> name
        name when is_binary(name) -> name
        _invalid -> nil
      end)

    Enum.all?(names, &is_binary/1) and names == Enum.uniq(names)
  end

  defp valid_source_and_action_tools?(_tools), do: false

  defp delivery_state(scenario) do
    lose_next_response =
      scenario.host_replay["model_events"]
      |> Enum.flat_map(&Map.get(&1, "faults", []))
      |> Enum.count(&(&1 == "lose_delivery_response"))

    %{
      deliveries: %{},
      lose_next_response: lose_next_response,
      order: [],
      receipts: %{}
    }
  end

  defp delivery_attempts(%{deliveries: deliveries, order: order}),
    do: Enum.map(order, &Map.fetch!(deliveries, &1))

  defp delivery_attempts(deliveries) when is_list(deliveries), do: Enum.reverse(deliveries)
end
