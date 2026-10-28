defmodule Ryker.WeeklyReport.ReviewExecutor do
  @moduledoc "The advisory weekly review's isolated, single-turn Coop lane."
  @behaviour Ryker.Coop.RunStep
  alias Ryker.Accounting
  alias Ryker.Coop
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.WeeklyReport.{ReviewCustody, ReviewFleetSession, ReviewPrompt}

  @doc """
  Moves the run on by one step: `{:ok, {:applied, candidate}}` once its
  diagnosis is saved, `{:ok, :waiting}` while Coop is still working,
  `{:ok, :stopped}` once the run ended without one and has stop proof, or an
  error for a step to try again.
  """
  @spec step(map(), struct(), map()) :: Coop.RunStep.result()
  def step(claim, run, settings) do
    run = run.id |> ReviewCustody.current() |> forgotten(claim)
    Coop.RunStep.step(__MODULE__, claim, run, nil, guarded_settings(run, settings))
  end

  defp guarded_settings(run, %{client: %CoopFleet.Client{} = client} = settings) do
    guard = fn
      "submit_turn", enqueue -> ReviewCustody.with_submission(run, settings, enqueue)
      _kind, enqueue -> enqueue.()
    end

    %{settings | client: CoopFleet.Client.with_enqueue_guard(client, guard)}
  end

  defp guarded_settings(_run, settings), do: settings

  # A person forgot something the run's prompt quotes while it was out: its
  # words are erased, so it only ever stops from here, never sends.
  defp forgotten(%{prompt: nil, status: status} = run, claim)
       when status in [:prepared, :responded] do
    case ReviewCustody.end_attempt(claim, run.id, :weekly_review_forgotten) do
      {:ok, ended} -> ended
      {:error, _reason} -> run
    end
  end

  defp forgotten(run, claim) do
    if run.status in [:prepared, :responded] and
         DateTime.compare(Repo.now!(), run.deadline_at) != :lt do
      case ReviewCustody.end_attempt(claim, run.id, :weekly_review_deadline) do
        {:ok, ended} -> ended
        {:error, _reason} -> run
      end
    else
      run
    end
  end

  @impl true
  def store, do: ReviewCustody

  @impl true
  def fleet_session, do: ReviewFleetSession

  @impl true
  def source(_run), do: nil

  @impl true
  def error(:execution_timeout), do: :weekly_review_execution_timeout
  def error(:lease_renewal_failed), do: :weekly_review_lease_renewal_failed
  def error(:provider_failed), do: :weekly_review_provider_failed
  def error(:remote_identity_conflict), do: :weekly_review_remote_identity_conflict
  def error(:remote_protocol_error), do: :weekly_review_remote_protocol_error
  def error(:remote_unresolved), do: :weekly_review_remote_unresolved
  def error(:session_authority_conflict), do: :weekly_review_session_authority_conflict
  def error(:session_identity_conflict), do: :weekly_review_session_identity_conflict
  def error(:session_not_isolated), do: :weekly_review_session_not_isolated
  def error(:session_unaddressable), do: :weekly_review_session_unaddressable

  @impl true
  def validate_key(run, sha256),
    do: "ryker:weekly_review:validate:#{run.id}:a#{run.candidate_attempt}:#{sha256}"

  @impl true
  def contract_version, do: ReviewPrompt.contract_version()

  @impl true
  def observe_in_transaction(candidate, run, session_id, turn, session, now) do
    Accounting.observe_weekly_review_in_transaction(
      candidate,
      run,
      session_id,
      turn,
      session,
      now
    )
  end

  # A person forgot what the prompt quotes while the answer was read, after
  # this step's own check (`forgotten/2`): the answer is not kept.
  @impl true
  def refused_candidate?(reason),
    do: reason in [:invalid_weekly_review_result, :weekly_review_forgotten]

  @impl true
  def check(_claim, run, _context, _settings) do
    case ReviewPrompt.parse(run.result, run.manifest) do
      {:ok, _diagnosis} ->
        :ok

      {:error, reason} ->
        if refused_candidate?(reason), do: {:stop, reason}, else: {:error, reason}
    end
  end
end
