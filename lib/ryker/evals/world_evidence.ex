defmodule Ryker.Evals.WorldEvidence do
  @moduledoc """
  Builds the report a model-world run leaves behind: the retained state
  records and their history, per-turn runtime evidence with the rebased input
  clock and provenance, the deliveries the evaluation adapters settled, the
  recorded source and state calls, and finally the judge's verdict or the
  execution error that stopped the run.
  """

  import Ecto.Query

  alias Ryker.Evals.{Evidence, WorldCase, WorldCassette, WorldInputs}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.State.{Record, Records}
  alias Ryker.Work.{ActivityEvent, Measurement, Turn}

  @doc """
  The full report for a run, before any assertion or judgment settles its
  status.
  """
  @spec report_data(WorldCase.t(), [map()], pid(), map(), [map()]) :: map()
  def report_data(scenario, executions, delivery_agent, settings, skipped) do
    execution = List.last(executions)
    episode_id = if execution, do: execution.episode.id

    %{
      deliveries: delivery_agent |> Agent.get(&delivery_attempts/1) |> Enum.map(&delivery/1),
      episode_id: episode_id,
      failures: [],
      quality: %{status: :unrun},
      record_history: if(episode_id, do: record_history(episode_id), else: []),
      records: if(episode_id, do: Records.retained_records(episode_id), else: []),
      runtime:
        scenario
        |> runtime_evidence(executions, settings, skipped)
        |> Map.put(:state_calls, if(episode_id, do: state_calls(episode_id), else: [])),
      scenario_id: scenario.id,
      source_calls: if(settings.cassette, do: WorldCassette.calls(settings.cassette), else: []),
      status: :unrun,
      turn_id: if(execution, do: execution.turn.id),
      turn_ids: Enum.map(executions, & &1.turn.id)
    }
  end

  @doc """
  Turns an execution error into a report that keeps every remote turn the
  failed run actually made, so the failure stays attributable after cleanup.
  """
  @spec retain_failure_report(
          {:ok, map()} | {:error, term()},
          WorldCase.t(),
          String.t(),
          map(),
          pid()
        ) ::
          {:ok, map()} | {:error, term()}
  def retain_failure_report({:ok, _report} = result, _scenario, _identity, _settings, _agent),
    do: result

  def retain_failure_report({:error, {:world_eval_assertions, _report}} = result, _, _, _, _),
    do: result

  def retain_failure_report({:error, reason}, scenario, identity, settings, agent) do
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

  @doc """
  Settles the report with the judge's verdict, or fails the run when the
  judge could not produce one.
  """
  @spec apply_judgment(term(), map()) :: {:ok, map()} | {:error, term()}
  def apply_judgment({:ok, %{decision: decision, status: status} = judgment}, report)
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

  def apply_judgment({:error, reason}, report),
    do: execution_failure(report, {:world_eval_judge, reason})

  def apply_judgment(other, report),
    do: execution_failure(report, {:world_eval_judge, {:invalid_result, other}})

  @doc false
  @spec current_submission_input(map()) :: map()
  def current_submission_input(%{turn: %{submission: %{"context" => context}}}) do
    context |> current_submission_inputs() |> List.last()
  end

  @doc false
  @spec state_calls(Ecto.UUID.t()) :: [map()]
  def state_calls(episode_id) when is_binary(episode_id) do
    Repo.all(
      from(event in ActivityEvent,
        where: event.episode_id == ^episode_id and event.kind == "tool.completed",
        order_by: [
          asc: event.occurred_at,
          asc: event.session_id,
          asc: event.sequence,
          asc: event.id
        ],
        select: event.payload
      )
    )
    |> Enum.flat_map(fn
      %{"input" => %{"server" => "responder-state", "tool" => tool}} = payload
      when is_binary(tool) and tool != "" ->
        outcome =
          if payload["status"] == "completed" and get_in(payload, ["output", "error"]) == nil,
            do: "succeeded",
            else: "failed"

        [%{"outcome" => outcome, "tool" => tool}]

      _other ->
        []
    end)
  end

  def state_calls(_episode_id), do: []

  defp execution_failure(report, reason) do
    report =
      report
      |> Map.put(:execution_error, reason)
      |> Map.put(:status, if(report.runtime.turns == [], do: :unrun, else: :failed))

    {:error, {:world_eval_assertions, report}}
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
        |> Enum.zip(WorldInputs.scenario_inputs(scenario))
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

  defp prompt_sha256(%{"prompt" => prompt}) when is_binary(prompt), do: sha256(prompt)
  defp prompt_sha256(_submission), do: nil

  defp decimal_string(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_string(nil), do: nil

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

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

  defp delivery_attempts(%{deliveries: deliveries, order: order}),
    do: Enum.map(order, &Map.fetch!(deliveries, &1))

  defp delivery_attempts(deliveries) when is_list(deliveries), do: Enum.reverse(deliveries)
end
