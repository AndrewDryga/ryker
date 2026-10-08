defmodule Ryker.Work.Dispatcher do
  @moduledoc """
  Claims and executes one durable episode work item.

  Model execution and external delivery use separate claim phases. A model
  worker never owns a Slack delivery, and a transient remote failure releases
  its lease before a bounded PostgreSQL-timed retry. Outcomes that cannot be
  retried safely enter explicit blocked custody instead of looping, and so does
  an exception raised by the executor, named by its module, and a turn whose
  claims already used up its attempts.
  """
  alias Ryker.Backoff
  alias Ryker.ErrorDetail
  alias Ryker.Reference
  alias Ryker.Work.{Custody, Executor}
  require Logger

  @type result ::
          {:ok,
           :idle
           | {:executed, map()}
           | {:deferred, term()}
           | {:blocked, term()}
           | {:lease_lost, term()}}
          | {:error, term()}

  @spec run_once(keyword()) :: result()
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <-
           Custody.claim_next(settings.worker_ref, settings.lease_seconds, :work) do
      execute_claim(claim, settings)
    end
  end

  @doc false
  @spec run_claim(map(), keyword()) :: result()
  def run_claim(claim, options) when is_map(claim) and is_list(options) do
    with {:ok, settings} <- settings(options), do: execute_claim(claim, settings)
  end

  def run_claim(_claim, _options), do: {:error, {:invalid_work_dispatcher, :claim}}

  defp execute_claim(nil, _settings), do: {:ok, :idle}

  # A claim spends an attempt before anything runs, so an executor that keeps
  # killing its worker would otherwise be claimed every lease period forever.
  defp execute_claim(
         %{turn: %{status: :pending, work_attempt_count: attempts}} = claim,
         %{max_attempts: maximum}
       )
       when attempts > maximum,
       do: stop_and_block(claim, {:work_retry_exhausted, :attempts})

  defp execute_claim(claim, settings) do
    executor_options =
      settings.executor_options
      |> Keyword.put(:lease_seconds, settings.lease_seconds)

    case run_executor(settings.executor, claim, executor_options) do
      {:ok, execution} ->
        {:ok, {:executed, execution}}

      {:error, reason} ->
        execution_failure(claim, reason, settings)
    end
  end

  # A database that cannot answer is the outage `Ryker.PollingWorker` backs off
  # from. Anything else raised here is a bug in Ryker: the turn stops with the
  # exception's module named and the stack in the log, instead of crashing the
  # worker and being claimed again every lease period with nothing recorded.
  defp run_executor(executor, claim, options) do
    executor.run(claim, options)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      reraise error, __STACKTRACE__

    error ->
      Logger.error(
        "work turn #{claim.turn.turn_ref} raised; it is stopped: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, {:work_host_exception, error.__struct__}}
  end

  # A person stopped the turn, or its lease ran out and another worker took it. Whoever holds
  # the turn now records what happens to it; this worker has no lease left to write with.
  defp execution_failure(_claim, :work_lease_lost = reason, _settings),
    do: {:ok, {:lease_lost, reason}}

  # What the briefing carried was withdrawn after Coop had the turn: the person edited or
  # deleted their message, or a fact it used was forgotten. The answer cannot be sent, and
  # finishing it was refused again, so it was stranded (2026-10-04 review); a new turn answers
  # from what is current.
  defp execution_failure(
         claim,
         {:work_completion_blocked, _receipt, :work_knowledge_context_stale} = reason,
         _settings
       ),
       do: rerun(claim, reason)

  # The same withdrawal found before the answer finished: on 2026-10-07 a later attempt of a
  # turn Coop already had found its briefing stale, and the turn stopped for a person.
  defp execution_failure(claim, :work_knowledge_context_stale = reason, _settings),
    do: rerun(claim, reason)

  defp execution_failure(claim, {:work_completion_blocked, receipt, reason}, _settings),
    do: block_completion(claim, receipt, reason)

  # A finished turn whose saving hit Coop down, a 5xx, a 429 or a command
  # timeout stopped at once and waited for a click, though trying again
  # finishes it (2026-10-04 review). Such a failure is tried again until the
  # turn's attempts run out.
  defp execution_failure(
         %{turn: %{status: :pending, completion_receipt: receipt}} = claim,
         reason,
         settings
       )
       when is_map(receipt) do
    if retry_class(reason) == :transient and claim.turn.work_attempt_count < settings.max_attempts,
      do: defer(claim, reported_reason(reason), settings),
      else: block_completion(claim, receipt, reason)
  end

  defp execution_failure(claim, {:work_execution_blocked, reason}, settings),
    do: stop_or_defer(claim, reason, settings)

  defp execution_failure(claim, {:work_poll_window_elapsed, phase} = reason, settings)
       when phase in [:operation, :turn],
       do: yield_progress(claim, reason, settings)

  defp execution_failure(claim, :work_derived_context_busy = reason, settings),
    do: yield_progress(claim, reason, settings)

  defp execution_failure(claim, reason, settings) do
    case retry_class(reason) do
      :transient -> retry_or_block(claim, reported_reason(reason), settings)
      :blocked -> stop_or_defer(claim, reason, settings)
    end
  end

  defp rerun(claim, reason) do
    case Custody.request_rerun(
           claim.episode.id,
           claim.episode.key,
           claim.turn.turn_ref,
           claim.turn.id,
           claim.lease_ref
         ) do
      {:ok, _request} -> {:ok, {:deferred, {:work_rerun_pending, reason}}}
      {:error, rerun_reason} -> custody_failed(reason, rerun_reason)
    end
  end

  defp retry_or_block(claim, reason, settings) do
    cond do
      claim.turn.status == :cancel_pending ->
        defer(claim, reason, settings)

      claim.turn.work_attempt_count >= settings.max_attempts ->
        stop_and_block(claim, {:work_retry_exhausted, reason})

      true ->
        defer(claim, reason, settings)
    end
  end

  defp defer(claim, reason, settings) do
    retry_seconds =
      Backoff.delay(
        attempt_count(claim.turn),
        settings.retry_base_seconds,
        settings.retry_max_seconds
      )

    {error_code, error_detail} = describe_error(reason)

    case Custody.defer(
           claim.episode.id,
           claim.turn.turn_ref,
           claim.lease_ref,
           retry_seconds,
           error_code,
           error_detail
         ) do
      {:ok, _turn} -> {:ok, {:deferred, reason}}
      {:error, defer_reason} -> custody_failed(reason, defer_reason)
    end
  end

  defp yield_progress(claim, reason, settings) do
    case Custody.yield_progress(
           claim.episode.id,
           claim.turn.turn_ref,
           claim.lease_ref,
           settings.retry_base_seconds
         ) do
      {:ok, _turn} -> {:ok, {:deferred, reason}}
      {:error, yield_reason} -> custody_failed(reason, yield_reason)
    end
  end

  defp stop_or_defer(%{turn: %{status: :cancel_pending}} = claim, reason, settings),
    do: defer(claim, reason, settings)

  defp stop_or_defer(claim, reason, _settings), do: stop_and_block(claim, reason)

  defp stop_and_block(claim, reason) do
    {error_code, error_detail} = describe_error(reason)
    detail = ErrorDetail.bound("#{error_code}: #{error_detail}")

    case Custody.request_block(
           claim.episode.id,
           claim.episode.key,
           claim.turn.turn_ref,
           claim.lease_ref,
           detail
         ) do
      {:ok, _request} -> {:ok, {:deferred, {:work_stop_pending, reason}}}
      {:error, stop_reason} -> custody_failed(reason, stop_reason)
    end
  end

  # The reason's own code is what the recovery brief reads to explain a stopped
  # completion; the completion receipt already says which kind of block this is.
  defp block_completion(claim, receipt, reason) do
    {code, detail} = describe_error(reason)

    case Custody.block_completion(
           claim.episode.id,
           claim.turn.turn_ref,
           claim.lease_ref,
           receipt,
           code,
           detail
         ) do
      {:ok, _turn} -> {:ok, {:blocked, reason}}
      {:error, block_reason} -> custody_failed(reason, block_reason)
    end
  end

  defp custody_failed(reason, :work_lease_lost), do: {:ok, {:lease_lost, reason}}

  defp custody_failed(reason, custody_reason),
    do: {:error, {:work_dispatch_failed, reason, custody_reason}}

  defp attempt_count(%{status: :cancel_pending, cancel_attempt_count: count}), do: count
  defp attempt_count(turn), do: turn.work_attempt_count

  defp retry_class({:work_generation_spent, _phase, _reason}), do: :transient
  defp retry_class({:work_cancellation_unresolved, _reason}), do: :transient
  defp retry_class({:coop_mutation_response_unresolved, _phase, _reason}), do: :transient
  defp retry_class({:coop_unavailable, _detail}), do: :transient
  defp retry_class({:coop_worker_command_timeout, _command_id}), do: :transient
  defp retry_class({:coop_upgrade_required, :repository_freshness_v2}), do: :transient
  defp retry_class({:coop_transport_error, _detail}), do: :transient
  defp retry_class({:coop_error, 429, _code, _detail}), do: :transient
  defp retry_class({:coop_error, status, _code, _detail}) when status >= 500, do: :transient
  # A fetch that stalled past its deadline, or a mirror another fetch holds;
  # one GitHub keeps refusing still blocks once the attempts run out.
  defp retry_class(:coop_worker_source_unavailable), do: :transient
  # Every worker was busy or not yet reporting. That passes, so the task is
  # tried again and asks a person only once its attempts run out; it stopped
  # for a person at once (2026-10-04 review).
  defp retry_class({:coop_worker_capacity_unavailable, _session_id}), do: :transient
  defp retry_class(_reason), do: :blocked

  defp reported_reason({:work_generation_spent, _phase, reason}), do: reason
  defp reported_reason(reason), do: reason

  defp describe_error(reason), do: ErrorDetail.describe(reason, :work_execution_failed)

  defp settings(options) when is_list(options) do
    allowed = [
      :executor,
      :executor_options,
      :lease_seconds,
      :max_attempts,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_ref
    ]

    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      validate_settings(%{
        executor: Keyword.get(options, :executor, Executor),
        executor_options: Keyword.get(options, :executor_options, []),
        lease_seconds: Keyword.get(options, :lease_seconds, 300),
        max_attempts: Keyword.get(options, :max_attempts, 8),
        retry_base_seconds: Keyword.get(options, :retry_base_seconds, 1),
        retry_max_seconds: Keyword.get(options, :retry_max_seconds, 60),
        worker_ref: Keyword.fetch!(options, :worker_ref)
      })
    else
      {:error, {:invalid_work_dispatcher, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_work_dispatcher, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_work_dispatcher, :options}}

  defp validate_settings(settings) do
    with :ok <- setting(is_atom(settings.executor), :executor),
         :ok <- setting(keyword?(settings.executor_options), :executor_options),
         :ok <- setting(positive?(settings.lease_seconds), :lease_seconds),
         :ok <- setting(positive?(settings.max_attempts), :max_attempts),
         :ok <- setting(positive?(settings.retry_base_seconds), :retry_base_seconds),
         :ok <-
           setting(
             Backoff.valid?(settings.retry_base_seconds, settings.retry_max_seconds),
             :retry_max_seconds
           ),
         :ok <- setting(Reference.valid?(settings.worker_ref), :worker_ref) do
      {:ok, settings}
    end
  end

  defp keyword?(value), do: is_list(value) and Keyword.keyword?(value)
  defp positive?(value), do: is_integer(value) and value > 0

  defp setting(true, _field), do: :ok
  defp setting(false, field), do: {:error, {:invalid_work_dispatcher, field}}
end
