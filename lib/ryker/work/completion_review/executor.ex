defmodule Ryker.Work.CompletionReview.Executor do
  @moduledoc "An isolated completion reviewer using the shared resumable Coop protocol."
  @behaviour Ryker.Coop.RunStep
  alias Ryker.Accounting
  alias Ryker.Coop
  alias Ryker.Work.CompletionReview.{Custody, FleetSession, Prompt}

  def step(claim, run, settings) do
    settings = Map.put(settings, :execution_timeout_seconds, 300)
    Coop.RunStep.step(__MODULE__, claim, run, nil, settings)
  end

  @impl true
  def store, do: Custody
  @impl true
  def fleet_session, do: FleetSession
  @impl true
  def source(_run), do: nil
  @impl true
  def contract_version, do: Prompt.contract_version()
  @impl true
  def validate_key(run, sha256), do: "ryker:completion-review:validate:#{run.id}:#{sha256}"
  @impl true
  def refused_candidate?(reason), do: reason == :invalid_completion_review
  @impl true
  def check(_claim, run, _context, _settings) do
    case Prompt.parse(run.result) do
      {:ok, _review} -> :ok
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def observe_in_transaction(turn, run, session_id, remote_turn, remote_session, now) do
    Accounting.observe_completion_review_in_transaction(
      turn,
      run,
      session_id,
      remote_turn,
      remote_session,
      now
    )
  end

  @impl true
  def error(:execution_timeout), do: :completion_review_execution_timeout
  def error(:lease_renewal_failed), do: :completion_review_lease_renewal_failed
  def error(:provider_failed), do: :completion_review_provider_failed
  def error(:remote_identity_conflict), do: :completion_review_remote_identity_conflict
  def error(:remote_protocol_error), do: :completion_review_remote_protocol_error
  def error(:remote_unresolved), do: :completion_review_remote_unresolved
  def error(:session_authority_conflict), do: :completion_review_session_authority_conflict
  def error(:session_identity_conflict), do: :completion_review_session_identity_conflict
  def error(:session_not_isolated), do: :completion_review_session_not_isolated
  def error(:session_unaddressable), do: :completion_review_session_unaddressable
end
