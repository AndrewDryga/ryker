defmodule Ryker.WeeklyReport.ReviewWorker do
  @moduledoc "Schedules one weekly advisory review and reconciles it even after reports are disabled."
  use Ryker.PollingWorker, lane: :weekly_review, interval: :poll_interval_ms
  alias Ryker.{Backoff, Crypto, Options, PollingWorker, Reference, Repo, Settings, WeeklyReport}
  alias Ryker.WeeklyReport.{ReviewCustody, ReviewEvidence, ReviewExecutor, ReviewFleetSession}
  require Logger

  @fields ~w(api client policy policy_digest worker_ref enabled poll_interval_ms execution_timeout_seconds lease_seconds)a

  def start_link(configuration),
    do: GenServer.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl PollingWorker
  def setup(configuration), do: {:ok, options!(configuration)}

  @doc false
  def options!(configuration) do
    settings =
      Options.normalize!(configuration, @fields, @fields,
        list: "weekly review requires unique known fields",
        map: "weekly review has missing or unknown fields",
        other: "weekly review configuration must be a map or keyword list"
      )

    unless Reference.valid?(settings.policy, 1024) and Crypto.sha256_hex?(settings.policy_digest) and
             is_boolean(settings.enabled) and is_atom(settings.api) and
             not is_nil(settings.client) and
             settings.poll_interval_ms in 100..60_000 and settings.lease_seconds in 30..600 and
             settings.execution_timeout_seconds in 30..600,
           do: raise(ArgumentError, "weekly review configuration is outside its bounds")

    settings
  end

  @impl PollingWorker
  def wake_on(_settings), do: [&Settings.subscribe/0]

  @impl PollingWorker
  def poll(settings) do
    case run_once(settings) do
      {:ok, :idle} ->
        settings.poll_interval_ms

      {:ok, _progress} ->
        2_000

      {:error, reason} ->
        Logger.warning("weekly review deferred: #{inspect(reason, limit: 5)}")
        settings.poll_interval_ms
    end
  end

  @doc "Advances a saved review by one durable step."
  def run_once(settings) do
    with {:ok, claim} <- ReviewCustody.claim(settings.worker_ref, settings.lease_seconds) do
      case claim do
        :idle -> {:ok, :idle}
        claim -> advance(claim, settings)
      end
    end
  end

  defp advance(%{review: %{started_at: nil}} = claim, settings) do
    review = claim.review
    empty? = evidence_empty?(review.manifest)

    cond do
      not settings.enabled ->
        skip(claim, :weekly_review_disabled)

      is_nil(review.prompt) ->
        skip(claim, :weekly_review_forgotten)

      empty? ->
        skip(claim, :weekly_review_no_evidence)

      not current_period?(review) ->
        skip(claim, :weekly_review_schedule_changed)

      DateTime.compare(Repo.now!(), review.deadline_at) != :lt ->
        skip(claim, :weekly_review_deadline)

      not ReviewEvidence.publishable?(review.manifest, review.conversation_ref) ->
        skip(claim, :weekly_review_source_revoked)

      not ReviewFleetSession.placeable?(settings) ->
        ReviewCustody.release(claim, 15)

      true ->
        with {:ok, review} <- ReviewCustody.begin_execution(claim),
             do: execute(claim, review, settings)
    end
  end

  defp advance(claim, settings) do
    review = claim.review

    reason =
      cond do
        not settings.enabled ->
          :weekly_review_disabled

        not current_period?(review) ->
          :weekly_review_schedule_changed

        not ReviewEvidence.publishable?(review.manifest, review.conversation_ref) ->
          :weekly_review_source_revoked

        true ->
          nil
      end

    if reason do
      with {:ok, ended} <- ReviewCustody.end_attempt(claim, review.id, reason),
           do: execute(claim, ended, settings)
    else
      execute(claim, review, settings)
    end
  end

  defp evidence_empty?(nil), do: true
  defp evidence_empty?(manifest), do: manifest["evidence"] == []

  defp current_period?(review) do
    case WeeklyReport.review_period() do
      {:ok, period} ->
        period.conversation_ref == review.conversation_ref and
          period.saved_at == review.settings_saved_at and
          period.week.from == review.period_start and period.week.to == review.period_end

      :off ->
        false
    end
  end

  defp skip(claim, reason) do
    with {:ok, _review} <- ReviewCustody.skip_unstarted(claim, reason),
         do: ReviewCustody.release(claim, 0)
  end

  defp execute(claim, review, settings) do
    result =
      with {:ok, _session} <-
             ReviewCustody.with_lease(claim, fn -> ReviewFleetSession.ensure(review) end),
           do: ReviewExecutor.step(claim, review, settings)

    case result do
      {:ok, {:applied, _review}} ->
        ReviewCustody.release(claim, 0)

      {:ok, :stopped} ->
        ReviewCustody.release(claim, 0)

      {:ok, :waiting} ->
        ReviewCustody.release(claim, 2)

      {:error, :weekly_review_lease_lost} ->
        {:error, :weekly_review_lease_lost}

      {:error, _reason} ->
        with {:ok, review} <- ReviewCustody.reconciliation_failed(claim) do
          ReviewCustody.release(claim, Backoff.delay(review.reconcile_attempt_count, 2, 60))
        end
    end
  end
end
