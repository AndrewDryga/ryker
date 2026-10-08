defmodule Ryker.Improvement.Executor do
  @moduledoc """
  Self-analysis's lane through `Ryker.Coop.RunStep`: an analysis run's
  session reads no repository, and an offered answer is checked against the
  contract (`Ryker.Improvement.Prompt.parse/1`) before Coop is told to accept
  it, as learning does. An answer that fails the check, or that the host
  cannot keep at all (`Ryker.Improvement.Analyses.record_candidate/4`), ends
  the run, and the next start gets a fresh prompt that says so.
  """
  @behaviour Ryker.Coop.RunStep
  alias Ryker.Accounting
  alias Ryker.Coop
  alias Ryker.Improvement.{Analyses, FleetSession, Prompt}

  @doc """
  Moves the run on by one step: `{:ok, {:applied, candidate}}` once its
  diagnosis is saved, `{:ok, :waiting}` while Coop is still working,
  `{:ok, :stopped}` once the run ended without one and has stop proof, or an
  error for a step to try again.
  """
  @spec step(map(), struct(), map()) :: Coop.RunStep.result()
  def step(claim, run, settings) do
    run = run.id |> Analyses.current() |> forgotten(claim)
    Coop.RunStep.step(__MODULE__, claim, run, nil, settings)
  end

  # A person forgot something the run's prompt quotes while it was out: its
  # words are erased, so it only ever stops from here, never sends.
  defp forgotten(%{prompt: nil, status: status} = run, claim)
       when status in [:prepared, :responded] do
    case Analyses.end_attempt(claim, run.id, :improvement_forgotten) do
      {:ok, ended} -> ended
      {:error, _reason} -> run
    end
  end

  defp forgotten(run, _claim), do: run

  @impl true
  def store, do: Analyses

  @impl true
  def fleet_session, do: FleetSession

  @impl true
  def source(_run), do: nil

  @impl true
  def error(:execution_timeout), do: :improvement_execution_timeout
  def error(:lease_renewal_failed), do: :improvement_lease_renewal_failed
  def error(:provider_failed), do: :improvement_provider_failed
  def error(:remote_identity_conflict), do: :improvement_remote_identity_conflict
  def error(:remote_protocol_error), do: :improvement_remote_protocol_error
  def error(:remote_unresolved), do: :improvement_remote_unresolved
  def error(:session_authority_conflict), do: :improvement_session_authority_conflict
  def error(:session_identity_conflict), do: :improvement_session_identity_conflict
  def error(:session_not_isolated), do: :improvement_session_not_isolated
  def error(:session_unaddressable), do: :improvement_session_unaddressable

  @impl true
  def validate_key(run, sha256),
    do: "ryker:improvement:validate:#{run.id}:a#{run.candidate_attempt}:#{sha256}"

  @impl true
  def contract_version, do: Prompt.contract_version()

  @impl true
  def observe_in_transaction(candidate, run, session_id, turn, session, now) do
    Accounting.observe_improvement_in_transaction(candidate, run, session_id, turn, session, now)
  end

  # A person forgot what the prompt quotes while the answer was read, after
  # this step's own check (`forgotten/2`): the answer is not kept.
  @impl true
  def refused_candidate?(reason),
    do: reason in [:invalid_improvement_result, :improvement_forgotten]

  @impl true
  def check(_claim, run, _context, _settings) do
    case Prompt.parse(run.result) do
      {:ok, _diagnosis} ->
        :ok

      {:error, reason} ->
        if refused_candidate?(reason), do: {:stop, reason}, else: {:error, reason}
    end
  end
end
