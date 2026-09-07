defmodule Responder.Admission.Dispatcher do
  @moduledoc """
  Claims and executes one durable ingress input.

  The inbox lease is the only queue ownership record. Coop operation keys make
  transport retries reconcile the same session and turn instead of spending a
  second model call.
  """

  alias Responder.Admission.{Executor, LeaseRenewer}
  alias Responder.Ingress.Inbox

  @maximum_error_detail_bytes 4_096
  @maximum_attempts 8

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
         {:ok, claim} <- Inbox.claim_next(settings.worker_ref, now, settings.lease_seconds) do
      execute_claim(claim, settings, now)
    end
  end

  defp execute_claim(nil, _settings, _now), do: {:ok, :idle}

  defp execute_claim(claim, settings, claimed_at) do
    input_ref = Inbox.ref(claim.entry)

    renew_lease =
      LeaseRenewer.new(claimed_at, settings.lease_seconds, settings.now, fn renewed_at ->
        case Inbox.renew(input_ref, claim.lease_ref, renewed_at, settings.lease_seconds) do
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
        {:ok, {:decided, execution}}

      {:error, {:admission_execution_blocked, reason}} ->
        block(claim, input_ref, reason)

      {:error, reason} ->
        if claim.entry.attempt_count >= @maximum_attempts do
          # A pending predecessor prevents every later input in its conversation
          # from running. Preserve reconciliation keys in operator custody rather
          # than retrying forever or silently discarding the offending input.
          {reported_reason, generation} = retry_reason(reason)
          block(claim, input_ref, reported_reason, generation)
        else
          defer(claim, input_ref, reason, settings, settings.now.())
        end
    end
  end

  defp block(claim, input_ref, reason, generation \\ :same) do
    {error_code, error_detail} = describe_error(reason)

    case Inbox.block(input_ref, claim.lease_ref, error_code, error_detail, generation) do
      {:ok, _entry} ->
        {:ok, {:blocked, input_ref, reason}}

      {:error, block_reason} ->
        {:error, {:admission_dispatch_failed, reason, block_reason}}
    end
  end

  defp defer(claim, input_ref, reason, settings, now) do
    delay_ms = retry_delay(claim.entry.attempt_count, settings)
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

  defp retry_reason({:admission_generation_spent, reason}), do: {reason, :execution}

  defp retry_reason({:admission_validation_generation_spent, reason}),
    do: {reason, :validation}

  defp retry_reason(reason), do: {reason, :same}

  defp defer_input(:execution, input_ref, lease_ref, now, delay_ms, code, detail) do
    Inbox.defer_after_terminal(input_ref, lease_ref, now, delay_ms, code, detail)
  end

  defp defer_input(:validation, input_ref, lease_ref, now, delay_ms, code, detail) do
    Inbox.defer_after_validation(input_ref, lease_ref, now, delay_ms, code, detail)
  end

  defp defer_input(:same, input_ref, lease_ref, now, delay_ms, code, detail) do
    Inbox.defer(input_ref, lease_ref, now, delay_ms, code, detail)
  end

  defp retry_delay(attempt_count, settings) do
    exponent = min(max(attempt_count - 1, 0), 20)
    min(settings.retry_base_ms * Integer.pow(2, exponent), settings.retry_max_ms)
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
  defp error_atom(atom) when is_atom(atom), do: atom
  defp error_atom(_reason), do: :admission_execution_failed

  defp settings(options) when is_list(options) do
    allowed = [
      :executor,
      :executor_options,
      :lease_seconds,
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
         :ok <- dispatcher_value(is_function(settings.now, 0), :now),
         :ok <- dispatcher_value(positive?(settings.retry_base_ms), :retry_base_ms),
         :ok <- valid_retry_max(settings),
         :ok <- dispatcher_value(valid_ref?(settings.worker_ref), :worker_ref) do
      {:ok, settings}
    end
  end

  defp valid_executor_options(options) do
    dispatcher_value(is_list(options) and Keyword.keyword?(options), :executor_options)
  end

  defp valid_retry_max(settings) do
    dispatcher_value(
      positive?(settings.retry_max_ms) and settings.retry_max_ms >= settings.retry_base_ms,
      :retry_max_ms
    )
  end

  defp dispatcher_value(true, _field), do: :ok
  defp dispatcher_value(false, field), do: {:error, {:invalid_admission_dispatcher, field}}

  defp positive?(value), do: is_integer(value) and value > 0

  defp valid_ref?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end
end
