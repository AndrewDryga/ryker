defmodule Responder.Work.Dispatcher do
  @moduledoc """
  Claims and executes one durable episode work item.

  Model execution and external delivery use separate claim phases. A model
  worker never owns a Slack delivery, and a transient remote failure releases
  its lease before a bounded PostgreSQL-timed retry. Outcomes that cannot be
  retried safely enter explicit blocked custody instead of looping.
  """

  alias Responder.Work.{Custody, Executor}

  @maximum_error_detail_bytes 4_096

  @type result ::
          {:ok, :idle | {:executed, map()} | {:deferred, term()} | {:blocked, term()}}
          | {:error, term()}

  @spec run_once(keyword()) :: result()
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <-
           Custody.claim_next(settings.worker_ref, settings.lease_seconds, :work) do
      execute_claim(claim, settings)
    end
  end

  defp execute_claim(nil, _settings), do: {:ok, :idle}

  defp execute_claim(claim, settings) do
    executor_options =
      settings.executor_options
      |> Keyword.put(:lease_seconds, settings.lease_seconds)

    case settings.executor.run(claim, executor_options) do
      {:ok, execution} ->
        {:ok, {:executed, execution}}

      {:error, {:work_execution_blocked, reason}} ->
        stop_or_defer(claim, reason, settings)

      {:error, {:work_poll_window_elapsed, phase} = reason}
      when phase in [:operation, :turn] ->
        yield_progress(claim, reason, settings)

      {:error, reason} ->
        case retry_class(reason) do
          :transient -> retry_or_block(claim, reported_reason(reason), settings)
          :blocked -> stop_or_defer(claim, reason, settings)
        end
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
    retry_seconds = retry_delay(attempt_count(claim.turn), settings)
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
      {:error, defer_reason} -> {:error, {:work_dispatch_failed, reason, defer_reason}}
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
      {:error, yield_reason} -> {:error, {:work_dispatch_failed, reason, yield_reason}}
    end
  end

  defp stop_or_defer(%{turn: %{status: :cancel_pending}} = claim, reason, settings),
    do: defer(claim, reason, settings)

  defp stop_or_defer(claim, reason, _settings), do: stop_and_block(claim, reason)

  defp stop_and_block(claim, reason) do
    {error_code, error_detail} = describe_error(reason)
    detail = "#{error_code}: #{error_detail}" |> bound_detail()

    case Custody.request_block(
           claim.episode.id,
           claim.episode.key,
           claim.turn.turn_ref,
           claim.lease_ref,
           detail
         ) do
      {:ok, _request} -> {:ok, {:deferred, {:work_stop_pending, reason}}}
      {:error, stop_reason} -> {:error, {:work_dispatch_failed, reason, stop_reason}}
    end
  end

  defp attempt_count(%{status: :cancel_pending, cancel_attempt_count: count}), do: count
  defp attempt_count(turn), do: turn.work_attempt_count

  defp retry_class({:work_generation_spent, _phase, _reason}), do: :transient
  defp retry_class({:work_cancellation_unresolved, _reason}), do: :transient
  defp retry_class({:coop_mutation_response_unresolved, _phase, _reason}), do: :transient
  defp retry_class({:coop_timeout, _phase}), do: :transient
  defp retry_class({:coop_unavailable, _detail}), do: :transient
  defp retry_class({:coop_transport_error, _detail}), do: :transient
  defp retry_class({:coop_error, 429, _code, _detail}), do: :transient
  defp retry_class({:coop_error, status, _code, _detail}) when status >= 500, do: :transient
  defp retry_class(_reason), do: :blocked

  defp reported_reason({:work_generation_spent, _phase, reason}), do: reason
  defp reported_reason(reason), do: reason

  defp retry_delay(attempt_count, settings) do
    exponent = min(max(attempt_count - 1, 0), 20)
    min(settings.retry_base_seconds * Integer.pow(2, exponent), settings.retry_max_seconds)
  end

  defp describe_error(reason) do
    code = reason |> error_atom() |> Atom.to_string()
    detail = reason |> inspect(limit: 20, printable_limit: 3_500, width: 120) |> bound_detail()
    {code, detail}
  end

  defp bound_detail(detail) when byte_size(detail) <= @maximum_error_detail_bytes, do: detail

  defp bound_detail(detail) do
    String.byte_slice(detail, 0, @maximum_error_detail_bytes - 3) <> "..."
  end

  defp error_atom({atom, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _third, _rest}) when is_atom(atom), do: atom
  defp error_atom(atom) when is_atom(atom), do: atom
  defp error_atom(_reason), do: :work_execution_failed

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
         :ok <- setting(valid_retry_max?(settings), :retry_max_seconds),
         :ok <- setting(reference?(settings.worker_ref), :worker_ref) do
      {:ok, settings}
    end
  end

  defp valid_retry_max?(settings) do
    positive?(settings.retry_max_seconds) and
      settings.retry_max_seconds >= settings.retry_base_seconds
  end

  defp keyword?(value), do: is_list(value) and Keyword.keyword?(value)
  defp positive?(value), do: is_integer(value) and value > 0

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end

  defp setting(true, _field), do: :ok
  defp setting(false, field), do: {:error, {:invalid_work_dispatcher, field}}
end
