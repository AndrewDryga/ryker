defmodule Ryker.Admission.Dispatcher do
  @moduledoc """
  Claims and executes one durable ingress input.

  The inbox lease is the only queue ownership record. Coop operation keys make
  transport retries reconcile the same session and turn instead of spending a
  second model call.
  """
  alias Ryker.Admission.{Executor, LeaseRenewer, UnavailableNote}
  alias Ryker.Backoff
  alias Ryker.Delivery
  alias Ryker.ErrorDetail
  alias Ryker.Ingress
  alias Ryker.Reference
  alias Ryker.Work
  require Logger

  @maximum_attempts 8
  # A provider that couldn't serve the model passes. OpenAI's was at capacity from about 05:25
  # to 06:10 UTC on 2026-10-13, when a question in Slack ran its five minutes without a word
  # and stopped, and it was read again only because another message came within the hour. Such
  # a message is read again by a fresh run after 1, 2, 4 and 8 minutes, then every 10, about an
  # hour in all, and only then waits for the worker to prove it works, as any worker failure
  # does. A waiting message holds back the later ones in its conversation, so no wait is longer
  # than 10 minutes past the provider's return.
  @provider_waits_ms [60_000, 120_000, 240_000, 480_000, 600_000, 600_000, 600_000, 600_000]

  @spec run_once(keyword()) ::
          {:ok,
           :idle
           | {:decided, map()}
           | {:deferred, String.t(), term()}
           | {:blocked, String.t(), term()}}
          | {:error, term()}
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         now <- settings.now.(),
         {:ok, claim} <-
           Ingress.Inbox.claim_next(settings.worker_ref, now, settings.lease_seconds) do
      execute_claim(claim, settings, now)
    end
  end

  defp execute_claim(nil, _settings, _now), do: {:ok, :idle}

  defp execute_claim(claim, settings, claimed_at) do
    input_ref = Ingress.Inbox.ref(claim.entry)

    renew_lease =
      LeaseRenewer.new(claimed_at, settings.lease_seconds, settings.now, fn renewed_at ->
        case Ingress.Inbox.renew(input_ref, claim.lease_ref, renewed_at, settings.lease_seconds) do
          {:ok, _entry} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)

    executor_options =
      settings.executor_options
      |> Keyword.put(:lease_ref, claim.lease_ref)
      |> Keyword.put(:renew_lease, renew_lease)

    case settings.executor.run(input_ref, executor_options) do
      {:ok, execution} ->
        recover_after_worker_failure(settings)
        {:ok, {:decided, execution}}

      {:error, {:admission_execution_blocked, reason}} ->
        block(claim, input_ref, reason)

      {:error, {:admission_generation_spent, {:coop_turn_failed, _, _, _} = reason}} ->
        # Coop owns provider failover and in-turn recovery. Once it declares
        # failure, the frozen request cannot fix its runtime or account, so the
        # message waits, and is read again once a later reading shows the
        # worker works (`Ingress.Inbox.recover_after_worker_failure/1`). A
        # provider outage passes, so it is read again on its own first.
        worker_failed(claim, input_ref, reason, settings)

      {:error, {:coop_timeout, _phase} = reason} ->
        # Coop was still creating the session or running the turn when this
        # claim's decision window closed, and the next claim reattaches to the
        # same operation. Waiting is not failing: Coop's turn timeout ends a
        # turn that never finishes, and readiness names an input left pending.
        wait(claim, input_ref, reason, settings, settings.now.())

      {:error, reason} ->
        dispatch_failure(claim, input_ref, reason, settings)
    end
  end

  defp dispatch_failure(
         claim,
         input_ref,
         {:coop_worker_capacity_unavailable, _session_id} = reason,
         settings
       ),
       do: wait_for_capacity(claim, input_ref, reason, :wait, settings)

  defp dispatch_failure(
         claim,
         input_ref,
         {:coop_worker_storage_refused, _session_id, _detail} = reason,
         settings
       ),
       do: wait_for_capacity(claim, input_ref, reason, :wait, settings)

  defp dispatch_failure(
         claim,
         input_ref,
         {:coop_error, _status, "storage_unavailable", _detail} = reason,
         settings
       ),
       do: wait_for_capacity(claim, input_ref, reason, :wait, settings)

  defp dispatch_failure(
         claim,
         input_ref,
         {:admission_generation_spent,
          {:coop_operation_failed, "storage_unavailable", _detail} = reason},
         settings
       ),
       do: wait_for_capacity(claim, input_ref, reason, :wait_execution, settings)

  defp dispatch_failure(claim, input_ref, {:coop_error, 429, _code, _detail} = reason, settings) do
    wait_for_rate_limit(claim, input_ref, reason, :wait, settings.retry_max_ms, settings.now.())
  end

  defp dispatch_failure(
         claim,
         input_ref,
         {:admission_generation_spent, {:coop_error, 429, _code, _detail} = reason},
         settings
       ) do
    wait_for_rate_limit(
      claim,
      input_ref,
      reason,
      :wait_execution,
      settings.retry_max_ms,
      settings.now.()
    )
  end

  defp dispatch_failure(claim, input_ref, reason, settings) do
    # A pending predecessor blocks later inputs in the conversation. Genuine
    # failures stay bounded; capacity waits above never spend this budget.
    if claim.entry.attempt_count >= @maximum_attempts do
      {reported_reason, generation} = retry_reason(reason)
      block(claim, input_ref, reported_reason, generation)
    else
      defer(claim, input_ref, reason, settings, settings.now.())
    end
  end

  # A person waiting on a model account nobody can fix by retrying hears so;
  # the note is courtesy, so a note that cannot be posted never changes what
  # happened to the input.
  defp tell_unavailable(entry, reason, settings) do
    {_code, detail} = describe_error(reason)

    with %Delivery.HostNote{} = note <- UnavailableNote.note(entry, detail, settings.now.()),
         {:error, failure} <- settings.notify.(note) do
      Logger.warning("model-unavailable note not posted: #{inspect(failure, limit: 5)}")
    end

    :ok
  end

  defp worker_failed(claim, input_ref, {:coop_turn_failed, _, code, detail} = reason, settings) do
    if Work.FailureCause.rate_limited?(code, detail) do
      delay_ms =
        Enum.at(
          @provider_waits_ms,
          claim.entry.execution_generation - 1,
          List.last(@provider_waits_ms)
        )

      wait_for_rate_limit(claim, input_ref, reason, :wait_execution, delay_ms, settings.now.())
    else
      retry_worker_failure(claim, input_ref, reason, settings)
    end
  end

  defp retry_worker_failure(
         claim,
         input_ref,
         {:coop_turn_failed, _, code, detail} = reason,
         settings
       ) do
    case provider_wait(claim.entry, code, detail) do
      nil ->
        with {:ok, _blocked} = blocked <- block_after_worker_failure(claim, input_ref, reason) do
          tell_unavailable(claim.entry, reason, settings)
          blocked
        end

      delay_ms ->
        wait_for_provider(claim, input_ref, reason, delay_ms, settings.now.())
    end
  end

  # A run that failed on something that passes (the provider couldn't serve it, or the model's
  # software failed on something it did not expect), or that ran out of time without a word from
  # the model, waits by the number of runs the message has had.
  defp provider_wait(entry, code, detail) do
    if code == "acp_timeout" or Work.FailureCause.transient?(detail),
      do: Enum.at(@provider_waits_ms, entry.execution_generation - 1)
  end

  defp wait_for_provider(claim, input_ref, reason, delay_ms, now) do
    {error_code, error_detail} = describe_error(reason)

    case defer_input(
           :execution,
           input_ref,
           claim.lease_ref,
           now,
           delay_ms,
           error_code,
           error_detail
         ) do
      {:ok, _entry} -> {:ok, {:deferred, input_ref, reason}}
      {:error, defer_reason} -> {:error, {:admission_dispatch_failed, reason, defer_reason}}
    end
  end

  defp block_after_worker_failure(claim, input_ref, reason) do
    {error_code, error_detail} = describe_error(reason)

    case Ingress.Inbox.block_after_worker_failure(
           input_ref,
           claim.lease_ref,
           error_code,
           error_detail
         ) do
      {:ok, _entry} -> {:ok, {:blocked, input_ref, reason}}
      {:error, block_reason} -> {:error, {:admission_dispatch_failed, reason, block_reason}}
    end
  end

  # A reading just finished, so the worker works: messages a worker failure stopped in the hour
  # before are read again. Reading them is courtesy to this one's outcome, so a failure here is
  # logged and changes nothing about it.
  defp recover_after_worker_failure(settings) do
    case Ingress.Inbox.recover_after_worker_failure(settings.now.()) do
      {:ok, _recovered} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "messages stopped by a worker failure not read again: #{inspect(reason, limit: 5)}"
        )
    end
  end

  defp block(claim, input_ref, reason, generation \\ :same) do
    {error_code, error_detail} = describe_error(reason)

    case Ingress.Inbox.block(input_ref, claim.lease_ref, error_code, error_detail, generation) do
      {:ok, _entry} ->
        {:ok, {:blocked, input_ref, reason}}

      {:error, block_reason} ->
        {:error, {:admission_dispatch_failed, reason, block_reason}}
    end
  end

  defp defer(claim, input_ref, reason, settings, now) do
    delay_ms =
      Backoff.delay(claim.entry.attempt_count, settings.retry_base_ms, settings.retry_max_ms)

    {reported_reason, generation} = retry_reason(reason)
    {error_code, error_detail} = describe_error(reported_reason)

    case defer_input(
           generation,
           input_ref,
           claim.lease_ref,
           now,
           delay_ms,
           error_code,
           error_detail
         ) do
      {:ok, _entry} ->
        {:ok, {:deferred, input_ref, reported_reason}}

      {:error, defer_reason} ->
        {:error, {:admission_dispatch_failed, reported_reason, defer_reason}}
    end
  end

  defp wait(claim, input_ref, reason, settings, now) do
    {error_code, error_detail} = describe_error(reason)

    case Ingress.Inbox.wait(
           input_ref,
           claim.lease_ref,
           now,
           settings.retry_base_ms,
           error_code,
           error_detail
         ) do
      {:ok, _entry} ->
        {:ok, {:deferred, input_ref, reason}}

      {:error, wait_reason} ->
        {:error, {:admission_dispatch_failed, reason, wait_reason}}
    end
  end

  # No model ran: the queue retains the request and returns the claim's attempt.
  # A confirmed creation failure still needs a fresh idempotency key next time.
  defp wait_for_capacity(claim, input_ref, reason, generation, settings) do
    {_error_code, error_detail} = describe_error(reason)

    case Ingress.Inbox.wait_for_capacity(
           input_ref,
           claim.lease_ref,
           settings.now.(),
           settings.retry_max_ms,
           "coop_worker_capacity_unavailable",
           error_detail,
           generation
         ) do
      {:ok, _entry} -> {:ok, {:deferred, input_ref, reason}}
      {:error, wait_reason} -> {:error, {:admission_dispatch_failed, reason, wait_reason}}
    end
  end

  defp wait_for_rate_limit(claim, input_ref, reason, generation, delay_ms, now) do
    {code, detail} = describe_error(reason)

    case Ingress.Inbox.wait_for_capacity(
           input_ref,
           claim.lease_ref,
           now,
           delay_ms,
           code,
           detail,
           generation
         ) do
      {:ok, _entry} -> {:ok, {:deferred, input_ref, reason}}
      {:error, wait_reason} -> {:error, {:admission_dispatch_failed, reason, wait_reason}}
    end
  end

  defp retry_reason({:admission_generation_spent, reason}), do: {reason, :execution}

  defp retry_reason({:admission_validation_generation_spent, reason}),
    do: {reason, :validation}

  defp retry_reason(reason), do: {reason, :same}

  defp defer_input(:execution, input_ref, lease_ref, now, delay_ms, code, detail) do
    Ingress.Inbox.defer_after_terminal(input_ref, lease_ref, now, delay_ms, code, detail)
  end

  defp defer_input(:validation, input_ref, lease_ref, now, delay_ms, code, detail) do
    Ingress.Inbox.defer_after_validation(input_ref, lease_ref, now, delay_ms, code, detail)
  end

  defp defer_input(:same, input_ref, lease_ref, now, delay_ms, code, detail) do
    Ingress.Inbox.defer(input_ref, lease_ref, now, delay_ms, code, detail)
  end

  defp describe_error({:coop_turn_failed, _state, code, _detail} = reason)
       when is_binary(code) and byte_size(code) in 1..120 do
    {code, ErrorDetail.detail(reason)}
  end

  defp describe_error(reason), do: ErrorDetail.describe(reason, :admission_execution_failed)

  defp settings(options) when is_list(options) do
    allowed = [
      :executor,
      :executor_options,
      :lease_seconds,
      :notify,
      :now,
      :retry_base_ms,
      :retry_max_ms,
      :worker_ref
    ]

    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      validate_settings(%{
        executor: Keyword.get(options, :executor, Executor),
        executor_options: Keyword.fetch!(options, :executor_options),
        lease_seconds: Keyword.get(options, :lease_seconds, 300),
        notify: Keyword.get(options, :notify, &Delivery.HostNote.deliver/1),
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        retry_base_ms: Keyword.get(options, :retry_base_ms, 1_000),
        retry_max_ms: Keyword.get(options, :retry_max_ms, 60_000),
        worker_ref: Keyword.fetch!(options, :worker_ref)
      })
    else
      {:error, {:invalid_admission_dispatcher, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_admission_dispatcher, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_admission_dispatcher, :options}}

  defp validate_settings(settings) do
    with :ok <- dispatcher_value(is_atom(settings.executor), :executor),
         :ok <- valid_executor_options(settings.executor_options),
         :ok <- dispatcher_value(positive?(settings.lease_seconds), :lease_seconds),
         :ok <- dispatcher_value(is_function(settings.notify, 1), :notify),
         :ok <- dispatcher_value(is_function(settings.now, 0), :now),
         :ok <- dispatcher_value(positive?(settings.retry_base_ms), :retry_base_ms),
         :ok <- valid_retry_max(settings),
         :ok <- dispatcher_value(Reference.valid?(settings.worker_ref), :worker_ref) do
      {:ok, settings}
    end
  end

  defp valid_executor_options(options) do
    dispatcher_value(is_list(options) and Keyword.keyword?(options), :executor_options)
  end

  defp valid_retry_max(settings) do
    dispatcher_value(
      Backoff.valid?(settings.retry_base_ms, settings.retry_max_ms),
      :retry_max_ms
    )
  end

  defp dispatcher_value(true, _field), do: :ok
  defp dispatcher_value(false, field), do: {:error, {:invalid_admission_dispatcher, field}}

  defp positive?(value), do: is_integer(value) and value > 0
end
