defmodule Ryker.Publication.FollowupDispatcher do
  @moduledoc false

  alias Ryker.Publication.{FollowupExecutor, Followups}

  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, delivery_claim} <-
           settings.custody.claim_delivery(settings.worker_ref, settings.lease_seconds) do
      case delivery_claim do
        nil -> poll_once(settings)
        claim -> execute(:delivery, claim, settings)
      end
    end
  end

  defp poll_once(settings) do
    with {:ok, claim} <- settings.custody.claim_poll(settings.worker_ref, settings.lease_seconds) do
      case claim do
        nil -> {:ok, :idle}
        claim -> execute(:poll, claim, settings)
      end
    end
  end

  defp execute(phase, claim, settings) do
    options =
      settings.executor_options
      |> Keyword.put(:interval_seconds, settings.interval_seconds)
      |> Keyword.put(:lease_seconds, settings.lease_seconds)

    result =
      case phase do
        :poll -> settings.executor.run_poll(claim, options)
        :delivery -> settings.executor.run_delivery(claim, options)
      end

    case result do
      {:ok, value} ->
        {:ok, {:executed, value}}

      {:error, reason} ->
        defer(phase, claim, reason, settings)
    end
  end

  defp defer(:poll, claim, reason, settings) do
    delay = backoff(claim.followup.failure_count + 1, settings)

    case settings.custody.defer_poll(
           claim.publication.ref,
           claim.lease_ref,
           delay,
           reason
         ) do
      {:ok, _followup} ->
        {:ok, {:deferred, reason}}

      {:error, defer_reason} ->
        {:error, {:publication_followup_dispatch_failed, reason, defer_reason}}
    end
  end

  defp defer(:delivery, claim, reason, settings) do
    delay = backoff(claim.event.attempt_count, settings)

    case settings.custody.defer_delivery(claim.event.ref, claim.lease_ref, delay, reason) do
      {:ok, _event} ->
        {:ok, {:deferred, reason}}

      {:error, defer_reason} ->
        {:error, {:publication_followup_dispatch_failed, reason, defer_reason}}
    end
  end

  defp backoff(attempt, settings) do
    exponent = min(max(attempt - 1, 0), 20)
    min(settings.retry_base_seconds * Integer.pow(2, exponent), settings.retry_max_seconds)
  end

  defp settings(options) when is_list(options) do
    allowed = [
      :custody,
      :executor,
      :executor_options,
      :interval_seconds,
      :lease_seconds,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_ref
    ]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      values = %{
        custody: Keyword.get(options, :custody, Followups),
        executor: Keyword.get(options, :executor, FollowupExecutor),
        executor_options: Keyword.get(options, :executor_options, []),
        interval_seconds: Keyword.get(options, :interval_seconds, 120),
        lease_seconds: Keyword.get(options, :lease_seconds, 60),
        retry_base_seconds: Keyword.get(options, :retry_base_seconds, 5),
        retry_max_seconds: Keyword.get(options, :retry_max_seconds, 1_800),
        worker_ref: Keyword.fetch!(options, :worker_ref)
      }

      with true <- callback?(values.custody, :claim_delivery, 2),
           true <- callback?(values.custody, :claim_poll, 2),
           true <- callback?(values.custody, :defer_delivery, 4),
           true <- callback?(values.custody, :defer_poll, 4),
           true <- callback?(values.executor, :run_delivery, 2),
           true <- callback?(values.executor, :run_poll, 2),
           true <- is_list(values.executor_options) and Keyword.keyword?(values.executor_options),
           true <- positive?(values.interval_seconds),
           true <- positive?(values.lease_seconds),
           true <- positive?(values.retry_base_seconds),
           true <- values.retry_max_seconds >= values.retry_base_seconds,
           true <- reference?(values.worker_ref) do
        {:ok, values}
      else
        false -> {:error, {:invalid_publication_followup_dispatcher, :settings}}
      end
    else
      {:error, {:invalid_publication_followup_dispatcher, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_publication_followup_dispatcher, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_publication_followup_dispatcher, :options}}

  defp callback?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)

  defp positive?(value), do: is_integer(value) and value > 0

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
