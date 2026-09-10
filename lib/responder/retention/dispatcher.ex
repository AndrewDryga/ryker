defmodule Responder.Retention.Dispatcher do
  @moduledoc "Claims and reconciles one durable Coop cleanup item."

  alias Responder.Retention.{Custody, Executor}

  @maximum_error_detail_bytes 4_096

  @spec run_once(keyword() | map()) ::
          {:ok, :idle | {:executed, map()} | {:deferred, term()} | {:blocked, term()}}
          | {:error, term()}
  def run_once(options) do
    with {:ok, settings} <- settings(options),
         {:ok, claim} <-
           Custody.claim_next(
             settings.worker_ref,
             settings.lease_seconds,
             settings.closed_session_grace_seconds
           ) do
      execute(claim, settings)
    end
  end

  defp execute(nil, _settings), do: {:ok, :idle}

  defp execute(claim, settings) do
    {api, client} = execution_adapter(claim.session.execution_kind, settings)

    executor_options = [
      api: api,
      client: client,
      closed_session_grace_seconds: settings.closed_session_grace_seconds
    ]

    case settings.executor.run(claim, executor_options) do
      {:ok, execution} ->
        {:ok, {:executed, execution}}

      {:error, reason} ->
        if transient?(reason) and claim.session.cleanup_attempt_count < settings.max_attempts,
          do: defer(claim, reason, settings),
          else: block(claim, reason)
    end
  end

  defp execution_adapter(:learning, settings),
    do: {settings.learning_api, settings.learning_client}

  defp execution_adapter(_execution_kind, settings), do: {settings.api, settings.client}

  defp defer(claim, reason, settings) do
    retry_seconds = retry_delay(claim.session.cleanup_attempt_count, settings)
    {code, detail} = describe(reason)

    case Custody.defer(claim.session.id, claim.lease_ref, retry_seconds, code, detail) do
      {:ok, _session} -> {:ok, {:deferred, reason}}
      {:error, defer_reason} -> {:error, {:retention_dispatch_failed, reason, defer_reason}}
    end
  end

  defp block(claim, reason) do
    {code, detail} = describe(reason)

    case Custody.block(claim.session.id, claim.lease_ref, code, detail) do
      {:ok, _session} -> {:ok, {:blocked, reason}}
      {:error, block_reason} -> {:error, {:retention_dispatch_failed, reason, block_reason}}
    end
  end

  defp transient?({:retention_generation_spent, _phase, _reason}), do: true
  defp transient?({:coop_mutation_response_unresolved, _phase, _reason}), do: true
  defp transient?({:coop_unavailable, _reason}), do: true
  defp transient?({:coop_transport_error, _reason}), do: true
  defp transient?({:coop_worker_capacity_unavailable, _session_id}), do: true
  defp transient?({:coop_error, 429, _code, _detail}), do: true
  defp transient?({:coop_error, status, _code, _detail}) when status >= 500, do: true
  defp transient?(_reason), do: false

  defp retry_delay(attempt, settings) do
    exponent = min(max(attempt - 1, 0), 20)
    min(settings.retry_base_seconds * Integer.pow(2, exponent), settings.retry_max_seconds)
  end

  defp describe(reason) do
    code = reason |> error_atom() |> Atom.to_string()
    detail = reason |> inspect(limit: 20, printable_limit: 3_500, width: 120) |> bound()
    {code, detail}
  end

  defp bound(value) when byte_size(value) <= @maximum_error_detail_bytes, do: value
  defp bound(value), do: String.byte_slice(value, 0, @maximum_error_detail_bytes - 3) <> "..."

  defp error_atom({atom, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _rest}) when is_atom(atom), do: atom
  defp error_atom({atom, _second, _third, _rest}) when is_atom(atom), do: atom
  defp error_atom(atom) when is_atom(atom), do: atom
  defp error_atom(_reason), do: :retention_failed

  @doc false
  @spec settings(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def settings(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: settings(Map.new(options)),
      else: {:error, {:invalid_retention_dispatcher, :options}}
  end

  def settings(%{} = options) do
    allowed = [
      :api,
      :client,
      :closed_session_grace_seconds,
      :executor,
      :learning_api,
      :learning_client,
      :lease_seconds,
      :max_attempts,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_ref
    ]

    settings = %{
      api: Map.get(options, :api, Responder.Coop.Client),
      client: Map.get(options, :client),
      closed_session_grace_seconds: Map.get(options, :closed_session_grace_seconds, 900),
      executor: Map.get(options, :executor, Executor),
      learning_api:
        Map.get(options, :learning_api, Map.get(options, :api, Responder.Coop.Client)),
      learning_client: Map.get(options, :learning_client, Map.get(options, :client)),
      lease_seconds: Map.get(options, :lease_seconds, 300),
      max_attempts: Map.get(options, :max_attempts, 8),
      retry_base_seconds: Map.get(options, :retry_base_seconds, 5),
      retry_max_seconds: Map.get(options, :retry_max_seconds, 300),
      worker_ref: Map.get(options, :worker_ref)
    }

    if known_options?(options, allowed) and dispatcher_dependencies_valid?(settings) and
         retry_settings_valid?(settings) and reference?(settings.worker_ref) do
      {:ok, settings}
    else
      {:error, {:invalid_retention_dispatcher, :options}}
    end
  end

  def settings(_options), do: {:error, {:invalid_retention_dispatcher, :options}}

  defp known_options?(options, allowed), do: Map.keys(options) -- allowed == []

  defp dispatcher_dependencies_valid?(settings) do
    is_atom(settings.api) and is_atom(settings.learning_api) and is_atom(settings.executor) and
      not is_nil(settings.client) and not is_nil(settings.learning_client) and
      nonnegative?(settings.closed_session_grace_seconds)
  end

  defp retry_settings_valid?(settings) do
    positive?(settings.lease_seconds) and positive?(settings.max_attempts) and
      positive?(settings.retry_base_seconds) and
      settings.retry_max_seconds >= settings.retry_base_seconds
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end
end
