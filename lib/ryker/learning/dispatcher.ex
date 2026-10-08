defmodule Ryker.Learning.Dispatcher do
  @moduledoc "Dispatches exclusively assigned original inputs; replying is a separate decision."
  alias Ryker.Learning.{Batches, EmptyChat, Executor, FleetSession}
  require Logger

  @maximum_reconciliations 12
  @refused_policy_hold_seconds 300
  @worker_hold_seconds 60
  # Coop's MaxTurnTimeout: a session policy cannot allow a longer turn.
  @longest_turn_seconds 24 * 3_600

  def run_once(settings) do
    case Batches.claim(settings.worker_ref, settings) do
      {:ok, :idle} ->
        {:ok, :idle}

      {:ok, %{inputs: []} = claim} ->
        if match?({:ok, _run}, Batches.fetch_outstanding(claim.batch.id)),
          do: resume(claim, settings),
          else: Batches.finish(claim, :superseded, "source_unavailable")

      {:ok, claim} ->
        resume(claim, settings)

      error ->
        error
    end
  end

  # The run still out, or else the latest; a batch with neither starts one.
  defp resume(claim, settings) do
    with {:error, :not_found} <- Batches.fetch_outstanding(claim.batch.id),
         {:error, :not_found} <- Batches.fetch_latest(claim.batch.id) do
      prepare(claim, settings)
    else
      {:ok, run} -> resume_run(claim, run, settings)
    end
  end

  defp resume_run(claim, %{status: :applied, remote_stopped_at: stopped} = run, _settings)
       when not is_nil(stopped), do: finish(claim, run)

  defp resume_run(claim, %{started_at: nil}, settings), do: prepare(claim, settings)

  defp resume_run(claim, %{remote_stopped_at: nil} = run, settings),
    do: execute(claim, run, settings)

  defp resume_run(claim, _run, settings), do: prepare(claim, settings)

  defp prepare(claim, settings) do
    cond do
      # Greetings, thanks and bare acknowledgements hold nothing a model could
      # learn (`EmptyChat`), so they end here without a call. A relearning a
      # person asked for always runs.
      is_nil(claim.batch.rebuild_target_id) and EmptyChat.all?(claim.inputs) ->
        Batches.finish(claim, :no_change, "nothing_to_learn")

      # Every session this policy creates is refused before a message is sent,
      # so a new attempt would only spend a start. Hold until the policy changes.
      Batches.policy_refused?(settings) ->
        Batches.yield(claim, @refused_policy_hold_seconds)

      # No worker would take the session now, so an attempt could only spend a
      # start proving nothing was created. Wait for one instead.
      not FleetSession.placeable?(settings) ->
        Batches.yield(claim, @worker_hold_seconds)

      true ->
        start(claim, settings)
    end
  end

  defp start(claim, settings) do
    with {:ok, claim} <- Batches.adopt_policy(claim, settings),
         {:ok, run} <- Batches.prepare(claim),
         {:ok, run} <- Batches.begin_execution(claim, run.id) do
      execute(claim, run, settings)
    else
      {:error, :learning_lease_lost} ->
        {:error, :learning_lease_lost}

      {:error, :learning_source_stale} ->
        unavailable_sources(claim, settings)

      {:error, :learning_capacity_exceeded} ->
        too_large(claim, settings)

      {:error, reason} ->
        Batches.finish(claim, :deferred, code(reason))
    end
  end

  # The largest message is left out and the rest are learned; a batch whose
  # every message was too large has nothing left to learn from.
  defp too_large(claim, settings) do
    case Batches.retire_largest(claim) do
      {:ok, %{inputs: []}} ->
        Batches.finish(claim, :superseded, "learning_input_too_large")

      {:ok, _claim} ->
        Batches.release(claim, :learning_input_too_large, settings.step_delay_seconds)

      {:error, :learning_capacity_exceeded} ->
        Batches.finish(claim, :deferred, "learning_capacity_exceeded")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unavailable_sources(claim, settings) do
    # A source can change between eligibility checking and freezing. Never
    # interpret one invalid member as permission to discard its valid siblings.
    case Batches.retire_unavailable(claim) do
      {:ok, %{inputs: []}} -> Batches.finish(claim, :superseded, "source_unavailable")
      {:ok, _} -> Batches.release(claim, :learning_source_stale, settings.step_delay_seconds)
      error -> error
    end
  end

  defp execute(claim, run, settings) do
    result =
      with {:ok, _} <- Batches.with_lease(claim, fn -> FleetSession.ensure(run) end),
           do: Executor.step(claim, run, settings)

    case result do
      {:ok, {:applied, applied}} ->
        finish(claim, applied)

      {:ok, :waiting} ->
        wait(claim, Batches.fetch_latest(claim.batch.id), settings)

      {:ok, :stopped} ->
        stopped(claim, Batches.fetch_latest(claim.batch.id), settings)

      {:error, :learning_lease_lost} ->
        {:error, :learning_lease_lost}

      {:error, reason} ->
        failed(claim, Batches.fetch_outstanding(claim.batch.id), reason, settings)
    end
  end

  defp wait(claim, {:ok, %{status: status} = run}, settings) when status in [:stale, :rejected],
    do: unresolved(claim, run, settings)

  defp wait(claim, _latest, settings), do: Batches.yield(claim, settings.step_delay_seconds)

  defp stopped(claim, {:ok, %{status: :applied} = run}, _settings), do: finish(claim, run)

  defp stopped(claim, {:ok, run}, settings),
    do: Batches.release(claim, stop_reason(run), settings.step_delay_seconds)

  # An attempt closed because its worker session can never be addressed sent
  # the model nothing, whatever its first stop was attempted for.
  defp stop_reason(%{stop_receipt: %{"session" => "unaddressable"}}),
    do: :learning_session_unconfirmed

  defp stop_reason(run), do: error_reason(run.error_code)

  defp failed(claim, {:error, :not_found}, reason, settings),
    do: Batches.release(claim, error_reason(code(reason)), settings.step_delay_seconds)

  defp failed(claim, {:ok, outstanding}, reason, settings),
    do: unresolved(claim, outstanding, settings, reason)

  defp unresolved(claim, run, settings, reason \\ nil) do
    with {:ok, run} <- Batches.reconciliation_failed(claim, run.id) do
      log_unresolved(run, reason || run.error_code)

      if run.reconcile_attempt_count >= @maximum_reconciliations do
        stop_unresolved(claim, run, settings)
      else
        Batches.yield(claim, min(Integer.pow(2, min(run.reconcile_attempt_count, 6)), 60))
      end
    end
  end

  defp stop_unresolved(claim, run, settings) do
    # One final fence/cancel is reconciliation, not another model execution.
    case Executor.stop(claim, run, :learning_remote_unresolved, settings) do
      {:ok, :stopped} ->
        Batches.release(
          claim,
          final_stop_reason(Batches.fetch_latest(claim.batch.id)),
          settings.step_delay_seconds
        )

      {:error, :learning_lease_lost} ->
        {:error, :learning_lease_lost}

      _ ->
        expire_or_wait(claim, run, settings)
    end
  end

  # A turn that may have reached the model waits for its worker's stop proof,
  # so uncertainty never buys a second model run. But no Coop turn outlives a
  # day, counted from the end of Ryker's own window to send one; past that
  # nothing more can arrive, and a conversation that waited longer waited
  # forever. Closing costs at most one duplicate model call.
  defp expire_or_wait(claim, run, settings) do
    closed_after = @longest_turn_seconds + settings.execution_timeout_seconds

    case Executor.expire(claim, run, closed_after) do
      {:ok, :stopped} ->
        Batches.release(claim, :learning_attempt_expired, settings.step_delay_seconds)

      {:error, :learning_lease_lost} ->
        {:error, :learning_lease_lost}

      _ ->
        Batches.release(claim, :learning_remote_unresolved, 0)
    end
  end

  defp final_stop_reason({:ok, %{stop_receipt: %{"session" => "unaddressable"}}}),
    do: :learning_session_unconfirmed

  defp final_stop_reason(_latest), do: :learning_execution_failed

  defp finish(claim, %{result: nil}),
    do: Batches.finish(claim, :applied, "learning_result_pruned")

  defp finish(claim, run) do
    %{"updates" => updates} = Jason.decode!(run.result)

    cond do
      Enum.any?(updates, &(&1["action"] in ["create", "update"])) ->
        Batches.finish(claim, :applied)

      Enum.any?(updates, &(&1["action"] == "defer")) ->
        Batches.finish(claim, :no_change, "learning_judgment_deferred")

      true ->
        Batches.finish(claim, :no_change)
    end
  end

  # The first tries and then every tenth, as repository knowledge does
  # (ffac2d7b): learning retried a step in silence (2026-10-04 review).
  defp log_unresolved(run, reason) do
    count = run.reconcile_attempt_count

    if count <= 3 or rem(count, 10) == 0 do
      Logger.warning(
        "learning could not take its next step for run #{run.id} (try #{count}): " <>
          inspect(reason, limit: 8, printable_limit: 300)
      )
    end
  end

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_), do: "learning_execution_failed"
  # Never turn provider or model text into atoms.
  defp error_reason(code) do
    Map.get(
      %{
        "knowledge_target_unavailable" => :knowledge_target_unavailable,
        "knowledge_match_ambiguous" => :knowledge_match_ambiguous,
        "learning_capacity_exceeded" => :learning_capacity_exceeded,
        "learning_match_required" => :learning_match_required,
        "learning_source_stale" => :learning_source_stale,
        "learning_context_stale" => :learning_context_stale,
        "output_contract_failed" => :output_contract_failed,
        "invalid_learning_result" => :invalid_learning_result,
        "learning_execution_timeout" => :learning_execution_timeout,
        "learning_provider_failed" => :learning_provider_failed,
        "learning_session_unconfirmed" => :learning_session_unconfirmed,
        "learning_session_not_isolated" => :learning_session_not_isolated
      },
      code,
      :learning_execution_failed
    )
  end
end
