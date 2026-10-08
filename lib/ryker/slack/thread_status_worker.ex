defmodule Ryker.Slack.ThreadStatusWorker do
  @moduledoc """
  Reconciles durable lifecycle state into generation-fenced Slack status writes.

  A message, a request or a status that changes is announced, and that wakes
  the worker at once. Otherwise it sleeps until a paced or retried write, or
  a shown status's refresh, falls due, or for its safety-net interval, which
  also catches a status that changes with the clock alone, such as a step
  that has gone quiet.
  """
  use Ryker.PollingWorker, lane: :slack_status, interval: :interval_ms
  alias Ryker.Delivery.Retry
  alias Ryker.Episodes
  alias Ryker.Ingress.Inbox
  alias Ryker.Observability.Progress
  alias Ryker.Options
  alias Ryker.PollingWorker
  alias Ryker.Slack.{ThreadStatuses, ThreadStatusReceipts}
  require Logger

  @default_interval_ms 1_000
  @default_maximum_writes 10
  @default_minimum_interval_ms 3_000
  @default_refresh_interval_ms 90_000
  @default_retry_base_ms 1_000
  @default_lease_seconds 30
  @default_max_attempts 8
  @maximum_backoff_ms 60_000

  def start_link(options) do
    options = options!(options)
    GenServer.start_link(__MODULE__, options, name: options.name)
  end

  @impl PollingWorker
  def wake_on(_options),
    do: [
      &Inbox.subscribe_inputs/0,
      &Episodes.subscribe_episodes/0,
      &ThreadStatuses.subscribe_thread_statuses/0
    ]

  @impl PollingWorker
  def poll(options) do
    {outcome, delay} =
      case run_once(options) do
        {:ok, %{failed: 0, written: 0} = outcome} ->
          {outcome, idle_delay(options)}

        {:ok, outcome} ->
          {outcome, 0}

        {:error, reason} ->
          Logger.warning("Slack thread-status worker failed: #{inspect(reason)}")
          {%{failed: 1, written: 0}, options.interval_ms}
      end

    _ = Progress.beat(:slack_status, if(outcome.failed == 0, do: :cycle, else: :error))
    delay
  end

  defp idle_delay(options) do
    PollingWorker.idle_delay(
      &ThreadStatuses.next_due_at(options.workspace_ref, &1, options.refresh_interval_ms),
      Map.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
    )
  end

  @spec run_once(map() | keyword()) ::
          {:ok, %{failed: non_neg_integer(), written: non_neg_integer()}} | {:error, term()}
  def run_once(options) do
    options = options!(options)

    with {:ok, targets} <- options.snapshot.(options.workspace_ref),
         {:ok, _statuses} <-
           ThreadStatuses.reconcile(
             options.workspace_ref,
             targets,
             options.minimum_interval_ms,
             options.refresh_interval_ms
           ) do
      deliver_due(options, options.maximum_writes, %{failed: 0, written: 0})
    end
  end

  defp deliver_due(_options, 0, outcome), do: {:ok, outcome}

  defp deliver_due(options, remaining, outcome) do
    case ThreadStatuses.claim_next(
           options.worker_ref,
           options.workspace_ref,
           options.lease_seconds
         ) do
      {:ok, nil} ->
        {:ok, outcome}

      {:ok, status} ->
        {result, outcome} = deliver(status, options, outcome)

        case result do
          :ok ->
            deliver_due(options, remaining - 1, outcome)

          {:error, :slack_thread_status_lease_lost} ->
            deliver_due(options, remaining - 1, outcome)

          {:error, _reason} ->
            deliver_due(options, remaining - 1, outcome)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver(status, options, outcome) do
    case options.api.set_thread_status(
           options.client,
           status.channel_ref,
           status.thread_ref,
           status.desired_text
         ) do
      :ok ->
        confirmation =
          with {:ok, _} <- ThreadStatusReceipts.record(status, :ok),
               do: ThreadStatuses.confirm(status.id, status.lease_ref, status.generation)

        case confirmation do
          {:ok, _confirmed} -> {:ok, Map.update!(outcome, :written, &(&1 + 1))}
          {:error, reason} -> {{:error, reason}, Map.update!(outcome, :failed, &(&1 + 1))}
        end

      {:error, reason} ->
        _ = ThreadStatusReceipts.record(status, {:error, reason})

        case settle(status, reason, options) do
          {:ok, _settled} ->
            {{:error, reason}, Map.update!(outcome, :failed, &(&1 + 1))}

          {:error, reason} ->
            {{:error, reason}, Map.update!(outcome, :failed, &(&1 + 1))}
        end
    end
  end

  # A write Slack refused is retried with growing waits until the status has
  # spent its attempts, then blocked for a person or for the next desired
  # status: one was written again every minute for as long as its thread
  # existed after Slack had said the channel was gone. Slack saying the
  # thread or its channel is gone blocks at once.
  #
  # Slack asking Ryker to slow down is no failed write: the status waits as
  # long as Slack asked, 30 seconds when it named no time, and keeps its
  # attempts.
  defp settle(status, reason, options) do
    case Retry.rate_limited(reason) do
      {:ok, seconds} ->
        ThreadStatuses.defer(
          status.id,
          status.lease_ref,
          status.generation,
          (seconds || 30) * 1_000,
          reason,
          counted: false
        )

      :error ->
        retry_or_block(status, reason, options)
    end
  end

  defp retry_or_block(status, reason, options) do
    if permanent?(reason) or status.attempt_count >= options.max_attempts do
      ThreadStatuses.block(status.id, status.lease_ref, status.generation, reason)
    else
      ThreadStatuses.defer(
        status.id,
        status.lease_ref,
        status.generation,
        retry_delay(status.attempt_count, options.retry_base_ms),
        reason
      )
    end
  end

  @permanent_refusals ~w(channel_not_found thread_not_found is_archived)

  defp permanent?({:slack_api_error, code}), do: code in @permanent_refusals
  defp permanent?(_reason), do: false

  defp retry_delay(attempt_count, base) do
    exponent = max(attempt_count - 1, 0) |> min(8)
    min(base * Integer.pow(2, exponent), @maximum_backoff_ms)
  end

  @doc false
  def options!(options) do
    required = [:api, :client, :snapshot, :worker_ref, :workspace_ref]

    optional = [
      :idle_interval_ms,
      :interval_ms,
      :lease_seconds,
      :max_attempts,
      :maximum_writes,
      :minimum_interval_ms,
      :name,
      :refresh_interval_ms,
      :retry_base_ms
    ]

    options =
      Options.normalize!(options, required ++ optional, required,
        list: "thread-status worker requires unique options",
        map: "invalid thread-status worker options",
        other: "invalid thread-status worker options"
      )

    prepared =
      options
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:lease_seconds, @default_lease_seconds)
      |> Map.put_new(:max_attempts, @default_max_attempts)
      |> Map.put_new(:maximum_writes, @default_maximum_writes)
      |> Map.put_new(:minimum_interval_ms, @default_minimum_interval_ms)
      |> Map.put_new(:name, nil)
      |> Map.put_new(:refresh_interval_ms, @default_refresh_interval_ms)
      |> Map.put_new(:retry_base_ms, @default_retry_base_ms)

    if valid_options?(prepared) do
      prepared
    else
      raise ArgumentError, "invalid thread-status worker options"
    end
  end

  defp valid_options?(options) do
    Enum.all?([
      is_atom(Map.get(options, :api)),
      function_exported?(Map.get(options, :api), :set_thread_status, 4),
      is_function(Map.get(options, :snapshot), 1),
      valid_ref?(Map.get(options, :worker_ref)),
      valid_ref?(Map.get(options, :workspace_ref)),
      Map.get(options, :interval_ms) in 50..3_600_000,
      Map.get(options, :idle_interval_ms, 50) in 50..3_600_000,
      Map.get(options, :lease_seconds) in 5..3_600,
      Map.get(options, :max_attempts) in 1..100,
      Map.get(options, :maximum_writes) in 1..100,
      Map.get(options, :minimum_interval_ms) in 100..60_000,
      Map.get(options, :refresh_interval_ms) in 60_000..110_000,
      Map.get(options, :retry_base_ms) in 100..60_000
    ])
  end

  defp valid_ref?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch
  end
end
