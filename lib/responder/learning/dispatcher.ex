defmodule Responder.Learning.Dispatcher do
  @moduledoc "Dispatches exclusively assigned original inputs; replying is a separate decision."
  alias Responder.Learning.{Batches, Executor, FleetSession}

  @maximum_reconciliations 12

  def run_once(settings) do
    case Batches.claim(settings.worker_ref, settings) do
      {:ok, :idle} ->
        {:ok, :idle}

      {:ok, %{inputs: []} = claim} ->
        if Batches.outstanding(claim.batch.id),
          do: resume(claim, settings),
          else: Batches.finish(claim, :superseded, "source_unavailable")

      {:ok, claim} ->
        resume(claim, settings)

      error ->
        error
    end
  end

  defp resume(claim, settings) do
    run = Batches.outstanding(claim.batch.id) || Batches.latest(claim.batch.id)
    resume_run(claim, run, settings)
  end

  defp resume_run(claim, %{status: :applied, remote_stopped_at: stopped} = run, _settings)
       when not is_nil(stopped), do: finish(claim, run)

  defp resume_run(claim, %{started_at: nil}, settings), do: prepare(claim, settings)

  defp resume_run(claim, %{remote_stopped_at: nil} = run, settings),
    do: execute(claim, run, settings)

  defp resume_run(claim, _run, settings), do: prepare(claim, settings)

  defp prepare(claim, settings) do
    with {:ok, run} <- Batches.prepare(claim),
         {:ok, run} <- Batches.begin_execution(claim, run.id) do
      execute(claim, run, settings)
    else
      {:error, :learning_lease_lost} = error ->
        error

      {:error, :learning_source_stale} ->
        unavailable_sources(claim, settings)

      {:error, reason} ->
        Batches.finish(claim, :deferred, code(reason))
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
        wait(claim, Batches.latest(claim.batch.id), settings)

      {:ok, :stopped} ->
        stopped(claim, Batches.latest(claim.batch.id), settings)

      {:error, :learning_lease_lost} = error ->
        error

      {:error, reason} ->
        failed(claim, Batches.outstanding(claim.batch.id), reason, settings)
    end
  end

  defp wait(claim, %{status: status} = run, settings) when status in [:stale, :rejected],
    do: unresolved(claim, run, settings)

  defp wait(claim, _run, settings), do: Batches.yield(claim, settings.step_delay_seconds)

  defp stopped(claim, %{status: :applied} = run, _settings), do: finish(claim, run)

  defp stopped(claim, run, settings),
    do: Batches.release(claim, error_reason(run.error_code), settings.step_delay_seconds)

  defp failed(claim, nil, reason, settings),
    do: Batches.release(claim, error_reason(code(reason)), settings.step_delay_seconds)

  defp failed(claim, outstanding, _reason, settings),
    do: unresolved(claim, outstanding, settings)

  defp unresolved(claim, run, settings) do
    with {:ok, run} <- Batches.reconciliation_failed(claim, run.id) do
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
        Batches.release(claim, :learning_execution_failed, settings.step_delay_seconds)

      {:error, :learning_lease_lost} = error ->
        error

      _ ->
        Batches.release(claim, :learning_remote_unresolved, 0)
    end
  end

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

  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_), do: "learning_execution_failed"
  # Never turn provider or model text into atoms.
  defp error_reason(code),
    do:
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
          "learning_provider_failed" => :learning_provider_failed
        },
        code,
        :learning_execution_failed
      )
end
