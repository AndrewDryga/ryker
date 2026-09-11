defmodule Responder.Retention.Dispatcher do
  @moduledoc """
  Claims and reconciles durable Coop cleanup items under a bounded budget.

  One pass advances at most one phase per session, stops at its batch limit or
  wall-time budget, and stops claiming further work for a worker that has
  already failed unreachably in the same pass, so one offline worker cannot
  consume the budget that the healthy ones need.
  """

  alias Responder.Retention.{Custody, Executor}

  @maximum_error_detail_bytes 4_096

  @type pass :: %{
          attempted: non_neg_integer(),
          blocked: non_neg_integer(),
          deferred: non_neg_integer(),
          executed: non_neg_integer(),
          idle: boolean(),
          stopped: :batch_limit | :time_budget | :idle | :error
        }

  @spec run_pass(keyword() | map()) :: {:ok, pass()} | {:error, term()}
  def run_pass(options) do
    with {:ok, settings} <- settings(options),
         {:ok, _reconsidered} <-
           Custody.reconsider_reconnected_workers(
             outage_error_codes(),
             settings.worker_reconnect_seconds
           ) do
      drain(settings, %{
        attempted: 0,
        blocked: 0,
        deadline: System.monotonic_time(:millisecond) + settings.batch_seconds * 1_000,
        deferred: 0,
        excluded_session_ids: [],
        excluded_worker_ids: [],
        executed: 0,
        idle: false,
        stopped: :batch_limit
      })
    end
  end

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

  defp drain(settings, state) do
    cond do
      state.attempted >= settings.batch_limit ->
        {:ok, summary(state, :batch_limit)}

      System.monotonic_time(:millisecond) >= state.deadline ->
        {:ok, summary(state, :time_budget)}

      true ->
        claim_and_execute(settings, state)
    end
  end

  defp claim_and_execute(settings, state) do
    case Custody.claim_next(
           settings.worker_ref,
           settings.lease_seconds,
           settings.closed_session_grace_seconds,
           session_ids: state.excluded_session_ids,
           worker_ids: state.excluded_worker_ids
         ) do
      {:ok, nil} ->
        {:ok, summary(%{state | idle: true}, :idle)}

      {:ok, claim} ->
        case execute(claim, settings) do
          {:error, reason} -> {:error, reason}
          outcome -> drain(settings, record(state, claim, outcome))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record(state, claim, outcome) do
    state = %{
      state
      | attempted: state.attempted + 1,
        excluded_session_ids: [claim.session.id | state.excluded_session_ids]
    }

    case outcome do
      {:ok, {:executed, _execution}} ->
        %{state | executed: state.executed + 1}

      {:ok, {:deferred, reason}} ->
        %{
          state
          | deferred: state.deferred + 1,
            excluded_worker_ids: exclude_worker(state.excluded_worker_ids, claim, reason)
        }

      {:ok, {:blocked, _reason}} ->
        %{state | blocked: state.blocked + 1}
    end
  end

  # A worker that just proved unreachable will fail every further call in this
  # pass identically. Stop claiming its work so the rest of the fleet drains.
  defp exclude_worker(excluded, %{worker_id: worker_id}, reason)
       when is_binary(worker_id) do
    if outage?(reason) and worker_id not in excluded,
      do: [worker_id | excluded],
      else: excluded
  end

  defp exclude_worker(excluded, _claim, _reason), do: excluded

  defp summary(state, stopped) do
    %{
      attempted: state.attempted,
      blocked: state.blocked,
      deferred: state.deferred,
      executed: state.executed,
      idle: state.idle,
      stopped: stopped
    }
  end

  defp execute(nil, _settings), do: {:ok, :idle}

  defp execute(claim, settings) do
    {api, client} = execution_adapter(claim.session.execution_kind, settings)

    executor_options = [
      api: api,
      client: client,
      closed_session_grace_seconds: settings.closed_session_grace_seconds,
      retained_recheck_seconds: settings.retained_recheck_seconds
    ]

    case settings.executor.run(claim, executor_options) do
      {:ok, execution} ->
        {:ok, {:executed, execution}}

      {:error, reason} ->
        if retryable?(reason, claim.session.cleanup_attempt_count, settings),
          do: defer(claim, reason, settings),
          else: block(claim, reason)
    end
  end

  # An outage is not a verdict about this session. A finite retry allowance
  # turned every worker outage longer than eight attempts into permanently
  # blocked cleanup that only an operator could restart.
  defp retryable?(reason, attempt_count, settings) do
    outage?(reason) or (transient?(reason) and attempt_count < settings.max_attempts)
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
  defp transient?(reason), do: outage?(reason)

  @doc false
  @spec outage?(term()) :: boolean()
  def outage?({:coop_unavailable, _reason}), do: true
  def outage?({:coop_transport_error, _reason}), do: true
  def outage?({:coop_worker_capacity_unavailable, _session_id}), do: true
  def outage?({:coop_error, 429, _code, _detail}), do: true
  def outage?({:coop_error, status, _code, _detail}) when status >= 500, do: true
  def outage?(_reason), do: false

  @doc "The durable error codes an outage leaves behind, for reconnect recovery."
  @spec outage_error_codes() :: [String.t()]
  def outage_error_codes,
    do: ~w(coop_unavailable coop_transport_error coop_worker_capacity_unavailable coop_error)

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
      :batch_limit,
      :batch_seconds,
      :client,
      :closed_session_grace_seconds,
      :executor,
      :learning_api,
      :learning_client,
      :lease_seconds,
      :max_attempts,
      :retained_recheck_seconds,
      :retry_base_seconds,
      :retry_max_seconds,
      :worker_reconnect_seconds,
      :worker_ref
    ]

    settings = %{
      api: Map.get(options, :api, Responder.Coop.Client),
      batch_limit: Map.get(options, :batch_limit, 25),
      batch_seconds: Map.get(options, :batch_seconds, 30),
      client: Map.get(options, :client),
      closed_session_grace_seconds: Map.get(options, :closed_session_grace_seconds, 900),
      executor: Map.get(options, :executor, Executor),
      learning_api:
        Map.get(options, :learning_api, Map.get(options, :api, Responder.Coop.Client)),
      learning_client: Map.get(options, :learning_client, Map.get(options, :client)),
      lease_seconds: Map.get(options, :lease_seconds, 300),
      max_attempts: Map.get(options, :max_attempts, 8),
      retained_recheck_seconds: Map.get(options, :retained_recheck_seconds, 21_600),
      retry_base_seconds: Map.get(options, :retry_base_seconds, 5),
      retry_max_seconds: Map.get(options, :retry_max_seconds, 300),
      worker_reconnect_seconds: Map.get(options, :worker_reconnect_seconds, 60),
      worker_ref: Map.get(options, :worker_ref)
    }

    if known_options?(options, allowed) and dispatcher_dependencies_valid?(settings) and
         retry_settings_valid?(settings) and budget_settings_valid?(settings) and
         reference?(settings.worker_ref) do
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

  defp budget_settings_valid?(settings) do
    positive?(settings.batch_limit) and settings.batch_limit <= 1_000 and
      positive?(settings.batch_seconds) and positive?(settings.retained_recheck_seconds) and
      positive?(settings.worker_reconnect_seconds)
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp nonnegative?(value), do: is_integer(value) and value >= 0

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end
end
