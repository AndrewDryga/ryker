defmodule Ryker.Improvement.Dispatcher do
  @moduledoc """
  One pass of the analysis queue (`Ryker.Improvement.Analyses`): lease the
  next candidate, resume the run it left outstanding or start a new one, and
  give the lease back with what happened.
  """

  alias Ryker.Improvement.{Analyses, Executor, FleetSession}

  @refused_policy_hold_seconds 300
  @worker_hold_seconds 60

  # How a run ended, as the atom its release records. Never turn a code read
  # back from the database into an atom it names.
  @codes %{
    "output_contract_failed" => :output_contract_failed,
    "invalid_improvement_result" => :invalid_improvement_result,
    "improvement_provider_failed" => :improvement_provider_failed,
    "improvement_execution_timeout" => :improvement_execution_timeout,
    "improvement_session_not_isolated" => :improvement_session_not_isolated,
    "improvement_attempt_expired" => :improvement_attempt_expired,
    "improvement_validation_unconfirmed" => :improvement_validation_unconfirmed
  }

  @spec run_once(map()) :: {:ok, atom() | term()} | {:error, term()}
  def run_once(settings) do
    case Analyses.claim(settings.worker_ref, settings) do
      {:ok, :idle} -> {:ok, :idle}
      {:ok, claim} -> resume(claim, settings)
      error -> error
    end
  end

  defp resume(claim, settings) do
    case Analyses.outstanding(claim.candidate.id) do
      nil -> start(claim, settings)
      run -> execute(claim, run, settings)
    end
  end

  defp start(claim, settings) do
    candidate = claim.candidate

    cond do
      not is_nil(candidate.forgotten_at) ->
        Analyses.finish_failed(claim, :improvement_forgotten)

      # A person dismissed it before Ryker got to it: no start is spent. It is
      # analyzed after all if someone accepts it later.
      candidate.status == :dismissed ->
        Analyses.yield(claim, 0)

      # Every session this policy creates is refused before anything is sent,
      # so a start would only prove that again. Hold until the policy changes.
      Analyses.policy_refused?(settings) ->
        Analyses.yield(claim, @refused_policy_hold_seconds)

      not FleetSession.placeable?(settings) ->
        Analyses.yield(claim, @worker_hold_seconds)

      true ->
        begin(claim, settings)
    end
  end

  defp begin(claim, settings) do
    with {:ok, run} <- Analyses.prepare(claim, settings),
         {:ok, run} <- Analyses.begin_execution(claim, run.id) do
      execute(claim, run, settings)
    else
      {:error, :improvement_lease_lost} = error ->
        error

      {:error, reason}
      when reason in [
             :improvement_evidence_unavailable,
             :improvement_prompt_too_large,
             :improvement_retry_exhausted
           ] ->
        Analyses.finish_failed(claim, reason)

      {:error, _reason} ->
        Analyses.release(claim, :improvement_preparation_failed, settings.retry_delay_seconds)
    end
  end

  defp execute(claim, run, settings) do
    result =
      with {:ok, _session} <- Analyses.with_lease(claim, fn -> FleetSession.ensure(run) end),
           do: Executor.step(claim, run, settings)

    case result do
      {:ok, {:applied, _candidate}} ->
        {:ok, :analyzed}

      {:ok, :waiting} ->
        Analyses.yield(claim, settings.step_delay_seconds)

      {:ok, :stopped} ->
        stopped = Analyses.current(run.id)

        Analyses.release(
          claim,
          Map.get(@codes, stopped.error_code, :improvement_execution_failed),
          settings.retry_delay_seconds
        )

      {:error, :improvement_lease_lost} = error ->
        error

      {:error, _reason} ->
        unresolved(claim, run)
    end
  end

  # Coop could not be asked, or its answer did not settle the step: nothing
  # is replaced; the same run is asked again, less often each time.
  defp unresolved(claim, run) do
    with {:ok, run} <- Analyses.reconciliation_failed(claim, run.id) do
      Analyses.yield(claim, min(Integer.pow(2, min(run.reconcile_attempt_count, 6)), 60))
    end
  end
end
