defmodule Responder.Evals.WorldRunner do
  @moduledoc """
  Runs one model-world scenario through the real episode, Work, state-record,
  validation, and delivery boundaries.

  The runner never contacts a platform publisher. Visible output is settled by
  an evaluation-only adapter, while Coop and the production Responder state
  tools remain real. Callers provide an isolated database and Coop policy.
  """

  import Ecto.Query

  alias Responder.Delivery.{Adapters, Dispatcher}
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}

  alias Responder.Evals.{
    Evidence,
    GitHubDeliveryPublisher,
    SlackDeliveryPublisher,
    WorldCase,
    WorldCassette,
    WorldMatch
  }

  alias Responder.Repo
  alias Responder.State.{Record, Records}
  alias Responder.Work.{Custody, Measurement}
  alias Responder.Work.Dispatcher, as: WorkDispatcher

  @fields [
    :api,
    :before_execute,
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
      evidence coverage finding progress alert_assessment input_request memory_offer preference_offer
      guidance_offer
    ),
    "read_only" => ~w(evidence coverage finding progress alert_assessment),
    "repository_feedback" =>
      ~w(evidence coverage finding progress alert_assessment input_request),
    "repository_write_offer" => ~w(task_offer input_request),
    "schedule_offer" => ~w(schedule_offer standing_assignment_offer automation_change_offer),
    "source_event" => ~w(evidence coverage finding progress alert_assessment event_wait)
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
    with :ok <- disposable_database(settings.cleanup) do
      scenario
      |> execute_without_cleanup(settings, delivery_agent)
      |> finish_execution(settings)
    end
  end

  defp execute_without_cleanup(scenario, settings, delivery_agent) do
    settings =
      if is_nil(settings.source_and_action_tools) do
        %{settings | source_and_action_tools: WorldCase.fabricated_tools(scenario)}
      else
        settings
      end

    identity = settings.id_generator.()
    episode_id = Ecto.UUID.generate()
    episode_key = "eval:#{scenario.id}:#{identity}"

    with :ok <- reference(identity, :identity),
         {:ok, adapters} <- eval_adapters(delivery_agent),
         {:ok, inputs} <- input_events(scenario),
         {:ok, executions} <-
           execute_inputs(
             inputs,
             scenario,
             settings,
             adapters,
             episode_id,
             episode_key,
             identity
           ),
         {:ok, report} <- assess(scenario, executions, delivery_agent, settings) do
      {:ok, report}
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:world_eval_runner_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:world_eval_runner_caught, kind, inspect(reason)}}
  end

  defp finish_execution(result, %{cleanup: false}), do: result

  defp finish_execution(result, %{cleanup: true} = settings) do
    cleanup_result = run_cleanup(settings.cleanup_remote, fn -> maybe_cleanup(true) end)

    finish_result(result, cleanup_result)
  end

  @doc false
  @spec run_cleanup((-> term()), (-> term())) :: :ok | {:error, term()}
  def run_cleanup(remote_cleanup, local_cleanup)
      when is_function(remote_cleanup, 0) and is_function(local_cleanup, 0) do
    remote_result = cleanup_call(remote_cleanup)
    local_result = cleanup_call(local_cleanup)

    case {remote_result, local_result} do
      {:ok, :ok} ->
        :ok

      {{:error, remote}, :ok} ->
        {:error, remote}

      {:ok, {:error, local}} ->
        {:error, local}

      {{:error, remote}, {:error, local}} ->
        {:error, {:model_world_cleanup_failures, remote, local}}
    end
  end

  @doc false
  @spec finish_result({:ok, map()} | {:error, term()}, :ok | {:error, term()}) ::
          {:ok, map()} | {:error, term()}
  def finish_result(result, :ok), do: result

  def finish_result({:error, primary}, {:error, cleanup}) do
    {:error, {:world_eval_failed_with_cleanup, primary, cleanup}}
  end

  def finish_result({:ok, _report}, {:error, cleanup}) do
    {:error, {:world_eval_cleanup_failed, cleanup}}
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

      not Enum.all?(inputs, &MapSet.member?(actor_refs, &1["actor_ref"])) ->
        {:error, {:invalid_world_runner, :input_actor}}

      true ->
        {:ok, inputs}
    end
  end

  defp scenario_inputs(%WorldCase{} = scenario) do
    initial = Enum.filter(scenario.events, &(&1["kind"] == "input"))

    scheduled =
      scenario.world["scheduled_events"]
      |> Enum.filter(&(&1["kind"] == "source_event"))
      |> Enum.map(&Map.put(&1, "kind", "input"))

    initial ++ scheduled
  end

  defp execute_inputs(inputs, scenario, settings, adapters, episode_id, episode_key, identity) do
    inputs
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {input, index}, {:ok, executions} ->
      case execute_input(
             input,
             index,
             scenario,
             settings,
             adapters,
             episode_id,
             episode_key,
             identity
           ) do
        {:ok, execution} -> {:cont, {:ok, [execution | executions]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, executions} -> {:ok, Enum.reverse(executions)}
      {:error, _reason} = error -> error
    end
  end

  defp execute_input(
         %{"actor_ref" => actor_ref, "occurred_at" => occurred_at, "payload" => %{} = payload} =
           input,
         index,
         scenario,
         settings,
         adapters,
         episode_id,
         episode_key,
         identity
       )
       when is_binary(actor_ref) and map_size(payload) > 0 do
    with {:ok, occurred_at, 0} <- DateTime.from_iso8601(occurred_at),
         {:ok, destination} <- input_destination(input),
         admit =
           %Command.AdmitInput{
             actor_ref: actor_ref,
             destination: destination,
             episode_id: episode_id,
             episode_key: episode_key,
             execution_mode: :live,
             native_input_id: "eval-input:#{scenario.id}:#{identity}:#{index}",
             occurred_at: occurred_at,
             payload: payload,
             revision: 1,
             turn_ref: "eval-turn:#{identity}:#{index}"
           },
         {:ok, transition} <- apply_world_input(admit),
         :ok <- maybe_pin_episode(index, transition.episode.id, settings),
         {:ok, claim} <- Custody.claim_next("#{settings.worker_ref}:work:#{index}", 300, :work),
         true <- claim.episode.id == transition.episode.id or {:error, :crossed_world_claim},
         :ok <- settings.before_execute.(claim, scenario),
         {:ok, execution} <- execute_work(claim, scenario, settings, index, 4),
         :ok <- accepted(execution),
         :ok <- deliver_message(execution, adapters, settings, index, 3) do
      {:ok, execution}
    else
      false -> {:error, {:world_eval_failed, :crossed_world_claim}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :input_event}}
    end
  end

  defp execute_input(
         _input,
         _index,
         _scenario,
         _settings,
         _adapters,
         _episode_id,
         _episode_key,
         _identity
       ),
       do: {:error, {:invalid_world_runner, :input_event}}

  defp apply_world_input(%Command.AdmitInput{} = admit) do
    case Episodes.fetch_by_key(admit.episode_key) do
      {:ok, %Episode{state: state} = episode}
      when state in [:waiting_for_input, :waiting_for_event] ->
        resume_world_wait(episode, admit)

      _new_or_working ->
        Episodes.apply(admit)
    end
  end

  defp resume_world_wait(episode, admit) do
    resume = %Command.ResumeWait{
      episode_key: episode.key,
      expected_wait: %{kind: episode.owner_kind, ref: episode.owner_ref},
      occurred_at: admit.occurred_at,
      resolution_ref: Command.dedupe_key(admit),
      turn_ref: admit.turn_ref
    }

    Repo.transaction(fn ->
      with {:ok, [_admitted, resumed]} <-
             Episodes.apply_batch_in_transaction([admit, resume]),
           :ok <- Records.resolve_wait_in_transaction(episode.owner_ref) do
        resumed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_pin_episode(1, episode_id, settings) do
    case Custody.pin_episode(episode_id, settings.policy, settings.policy_digest, nil) do
      {:ok, _session} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_pin_episode(_index, _episode_id, _settings), do: :ok

  defp accepted(%{status: :accepted, turn: %{status: :delivery_pending}}), do: :ok
  defp accepted(execution), do: {:error, {:world_eval_failed, {:work_not_accepted, execution}}}

  defp execute_work(_claim, _scenario, _settings, _index, 0),
    do: {:error, {:world_eval_failed, :work_retry_exhausted}}

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

      other ->
        {:error, {:world_eval_failed, {:work_result, other}}}
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
              transport in ~w(slack github) do
    {:ok, %{conversation_ref: conversation_ref, thread_ref: thread_ref, transport: transport}}
  end

  defp input_destination(%{"destination" => _invalid}),
    do: {:error, {:invalid_world_runner, :destination}}

  defp input_destination(_input) do
    {:ok,
     %{
       conversation_ref: "slack:TEVAL:CEVAL",
       thread_ref: "1788019200.000100",
       transport: "slack"
     }}
  end

  defp assess(scenario, executions, delivery_agent, settings) do
    execution = List.last(executions)
    records = Records.model_records(execution.episode.id)
    record_history = record_history(execution.episode.id)
    calls = if settings.cassette, do: WorldCassette.calls(settings.cassette), else: []
    deliveries = delivery_agent |> Agent.get(&delivery_attempts/1) |> Enum.map(&delivery/1)

    failures =
      actor_authority_failures(scenario, executions) ++
        hard_failures(
          scoped_hard_checks(scenario.expect["hard"], settings.expectation_mode),
          record_history,
          executions,
          deliveries
        ) ++
        trajectory_failures(scenario.expect["trajectory"], calls)

    report = %{
      deliveries: deliveries,
      episode_id: execution.episode.id,
      failures: failures,
      quality: %{status: :unrun},
      record_history: record_history,
      records: records,
      runtime: runtime_evidence(scenario, executions, settings),
      scenario_id: scenario.id,
      source_calls: calls,
      status: if(failures == [], do: :unrun, else: :failed),
      turn_id: execution.turn.id,
      turn_ids: Enum.map(executions, & &1.turn.id)
    }

    cond do
      failures != [] -> {:error, {:world_eval_assertions, report}}
      is_nil(settings.judge) -> {:ok, report}
      true -> apply_judgment(settings.judge.(scenario, report), report)
    end
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

  defp runtime_evidence(scenario, executions, settings) do
    %{
      policy: settings.policy,
      policy_digest: settings.policy_digest,
      tool_catalog_sha256: settings.tool_catalog_sha256 || scenario.tool_catalog_digest,
      tool_names: settings.tool_names || catalog_tool_names(scenario.tool_catalog),
      turns: Enum.map(executions, &turn_evidence/1)
    }
  end

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

  defp apply_judgment({:error, reason}, _report), do: {:error, {:world_eval_judge, reason}}
  defp apply_judgment(other, _report), do: {:error, {:world_eval_judge, {:invalid_result, other}}}

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
    actor = Map.fetch!(actors, input["actor_ref"])
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
    identity = task_identity(record)
    authorized = record_authorized?(record, actor, allowed, identity, identities)

    identities =
      if authorized and identity, do: MapSet.put(identities, identity), else: identities

    if authorized,
      do: {failures, identities},
      else: {[unauthorized_record(record, actor) | failures], identities}
  end

  defp record_authorized?(record, actor, allowed, identity, identities) do
    record.kind in allowed or
      (actor["authority"] == "repository_feedback" and record.kind == "task_offer" and
         not is_nil(identity) and MapSet.member?(identities, identity))
  end

  defp unauthorized_record(record, actor) do
    %{
      "actor_ref" => actor["actor_ref"],
      "authority" => actor["authority"],
      "kind" => "unauthorized_state_record",
      "record_kind" => record.kind,
      "record_ref" => record.ref
    }
  end

  defp task_identity(%Record{
         kind: "task_offer",
         payload: %{"instruction_ref" => instruction_ref, "repository" => repository}
       })
       when is_binary(instruction_ref) and is_binary(repository),
       do: {repository, instruction_ref}

  defp task_identity(_record), do: nil

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
