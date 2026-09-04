defmodule Responder.Publication.Dispatcher do
  @moduledoc """
  Claims and advances one durable publication phase.

  A failure never erases an approved publication or abandons an ambiguous
  external mutation. Custody is released with bounded PostgreSQL-timed backoff
  so a later claimant reconciles the same review, delivery, or draft request.
  """

  alias Responder.Publication.{Custody, Executor}

  @maximum_error_detail_bytes 4_096

  @spec run_once(keyword()) ::
          {:ok, :idle | {:executed, map()} | {:deferred, term()}} | {:error, term()}
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <- Custody.claim_next(settings.worker_ref, settings.lease_seconds) do
      execute(claim, settings)
    end
  end

  defp execute(nil, _settings), do: {:ok, :idle}

  defp execute(claim, settings) do
    executor_options =
      settings.executor_options
      |> Keyword.put(:lease_seconds, settings.lease_seconds)

    case settings.executor.run(claim, executor_options) do
      {:ok, result} ->
        {:ok, {:executed, result}}

      {:error, reason} ->
        delay = retry_delay(claim.publication.attempt_count, settings)
        {code, detail} = describe(reason)

        case Custody.defer(claim.publication.ref, claim.lease_ref, delay, code, detail) do
          {:ok, _publication} ->
            {:ok, {:deferred, reason}}

          {:error, defer_reason} ->
            {:error, {:publication_dispatch_failed, reason, defer_reason}}
        end
    end
  end

  defp retry_delay(attempt_count, settings) do
    exponent = min(max(attempt_count - 1, 0), 20)
    min(settings.retry_base_seconds * Integer.pow(2, exponent), settings.retry_max_seconds)
  end

  defp describe(reason) do
    code = reason |> error_atom() |> Atom.to_string()

    detail =
      reason
      |> inspect(limit: 20, printable_limit: 3_500, width: 120)
      |> bound_detail()

    {code, detail}
  end

  defp bound_detail(detail) when byte_size(detail) <= @maximum_error_detail_bytes, do: detail

  defp bound_detail(detail),
    do: String.byte_slice(detail, 0, @maximum_error_detail_bytes - 3) <> "..."

  defp error_atom({:publication_conflict, atom, _receipt}) when is_atom(atom), do: atom
  defp error_atom({atom, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _third, _rest}) when is_atom(atom), do: atom
  defp error_atom(atom) when is_atom(atom), do: atom
  defp error_atom(_reason), do: :publication_failed

  defp settings(options) when is_list(options) do
    allowed = [
      :executor,
      :executor_options,
      :lease_seconds,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_ref
    ]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      validate_settings(%{
        executor: Keyword.get(options, :executor, Executor),
        executor_options: Keyword.get(options, :executor_options, []),
        lease_seconds: Keyword.get(options, :lease_seconds, 60),
        retry_base_seconds: Keyword.get(options, :retry_base_seconds, 1),
        retry_max_seconds: Keyword.get(options, :retry_max_seconds, 60),
        worker_ref: Keyword.fetch!(options, :worker_ref)
      })
    else
      {:error, {:invalid_publication_dispatcher, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_publication_dispatcher, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_publication_dispatcher, :options}}

  defp validate_settings(settings) do
    with true <- is_atom(settings.executor),
         true <-
           is_list(settings.executor_options) and Keyword.keyword?(settings.executor_options),
         true <- positive?(settings.lease_seconds),
         true <- positive?(settings.retry_base_seconds),
         true <- positive?(settings.retry_max_seconds),
         true <- settings.retry_max_seconds >= settings.retry_base_seconds,
         true <- reference?(settings.worker_ref) do
      {:ok, settings}
    else
      false -> {:error, {:invalid_publication_dispatcher, :settings}}
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
