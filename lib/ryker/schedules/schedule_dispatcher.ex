defmodule Ryker.Schedules.ScheduleDispatcher do
  @moduledoc false
  alias Ryker.Adapter
  alias Ryker.Backoff
  alias Ryker.Reference
  alias Ryker.Schedules

  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <- settings.custody.claim_due(settings.worker_ref, settings.lease_seconds) do
      case claim do
        nil ->
          {:ok, :idle}

        claim ->
          execute(claim, settings)
      end
    end
  end

  @doc """
  The earliest moment after `since` at which the configured schedule custody
  has an occurrence, retry or unrenewed lease due, or nil; a custody that
  cannot say has nothing the worker could sleep until.
  """
  @spec next_due_at(keyword(), DateTime.t()) :: DateTime.t() | nil
  def next_due_at(options, %DateTime{} = since) do
    custody = Keyword.get(options, :custody, Schedules)

    if Adapter.implements?(custody, next_due_at: 1),
      do: custody.next_due_at(since)
  end

  defp execute(claim, settings) do
    case settings.custody.dispatch(
           claim.schedule.ref,
           claim.lease_ref,
           settings.policy_resolver,
           settings.misfire_grace_seconds
         ) do
      {:ok, result} ->
        {:ok, {:executed, result}}

      {:error, reason} ->
        delay =
          Backoff.delay(
            claim.schedule.failure_count + 1,
            settings.retry_base_seconds,
            settings.retry_max_seconds
          )

        case settings.custody.defer(claim.schedule.ref, claim.lease_ref, delay, reason) do
          {:ok, _schedule} -> {:ok, {:deferred, reason}}
          {:error, defer_reason} -> {:error, {:schedule_dispatch_failed, reason, defer_reason}}
        end
    end
  end

  defp settings(options) when is_list(options) do
    allowed = [
      :custody,
      :lease_seconds,
      :misfire_grace_seconds,
      :policy_resolver,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_ref
    ]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      values = %{
        custody: Keyword.get(options, :custody, Schedules),
        lease_seconds: Keyword.get(options, :lease_seconds, 60),
        misfire_grace_seconds: Keyword.get(options, :misfire_grace_seconds, 900),
        policy_resolver: Keyword.fetch!(options, :policy_resolver),
        retry_base_seconds: Keyword.get(options, :retry_base_seconds, 5),
        retry_max_seconds: Keyword.get(options, :retry_max_seconds, 1_800),
        worker_ref: Keyword.fetch!(options, :worker_ref)
      }

      with true <- Adapter.implements?(values.custody, claim_due: 2, dispatch: 4, defer: 4),
           true <- is_function(values.policy_resolver, 1),
           true <- positive?(values.lease_seconds),
           true <- non_negative?(values.misfire_grace_seconds),
           true <- positive?(values.retry_base_seconds),
           true <- Backoff.valid?(values.retry_base_seconds, values.retry_max_seconds),
           true <- Reference.valid?(values.worker_ref) do
        {:ok, values}
      else
        false -> {:error, {:invalid_schedule_dispatcher, :settings}}
      end
    else
      {:error, {:invalid_schedule_dispatcher, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_schedule_dispatcher, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_schedule_dispatcher, :options}}

  defp positive?(value), do: is_integer(value) and value > 0
  defp non_negative?(value), do: is_integer(value) and value >= 0
end
