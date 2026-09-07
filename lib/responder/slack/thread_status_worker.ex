defmodule Responder.Slack.ThreadStatusWorker do
  alias Responder.Slack.ThreadStatusReceipts

  @moduledoc """
  Reconciles durable lifecycle state into generation-fenced Slack status writes.
  """

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Polling
  alias Responder.Slack.ThreadStatuses

  @default_interval_ms 1_000
  @default_maximum_writes 10
  @default_minimum_interval_ms 3_000
  @default_refresh_interval_ms 90_000
  @default_retry_base_ms 1_000
  @default_lease_seconds 30
  @maximum_backoff_ms 60_000

  def start_link(options) do
    options = options!(options)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl GenServer
  def init(options) do
    send(self(), :work)
    {:ok, options}
  end

  @impl GenServer
  def handle_info(:work, options) do
    delay =
      Polling.run(:slack_status, options.interval_ms, fn ->
        outcome =
          case run_once(options) do
            {:ok, outcome} ->
              outcome

            {:error, reason} ->
              Logger.warning("Slack thread-status worker failed: #{inspect(reason)}")
              %{failed: 1, written: 0}
          end

        _ = Progress.beat(:slack_status, if(outcome.failed == 0, do: :cycle, else: :error))
        options.interval_ms
      end)

    Process.send_after(self(), :work, delay)
    {:noreply, options}
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

      {:error, _reason} = error ->
        error
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
          {:error, _reason} = error -> {error, Map.update!(outcome, :failed, &(&1 + 1))}
        end

      {:error, reason} ->
        _ = ThreadStatusReceipts.record(status, {:error, reason})
        retry_ms = retry_delay(status.attempt_count, options.retry_base_ms)

        case ThreadStatuses.defer(
               status.id,
               status.lease_ref,
               status.generation,
               retry_ms,
               reason
             ) do
          {:ok, _deferred} ->
            {{:error, reason}, Map.update!(outcome, :failed, &(&1 + 1))}

          {:error, _reason} = error ->
            {error, Map.update!(outcome, :failed, &(&1 + 1))}
        end
    end
  end

  defp retry_delay(attempt_count, base) do
    exponent = max(attempt_count - 1, 0) |> min(8)
    min(base * Integer.pow(2, exponent), @maximum_backoff_ms)
  end

  @doc false
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "thread-status worker requires unique options")
  end

  def options!(%{} = options) do
    required = [:api, :client, :snapshot, :worker_ref, :workspace_ref]

    optional = [
      :interval_ms,
      :lease_seconds,
      :maximum_writes,
      :minimum_interval_ms,
      :name,
      :refresh_interval_ms,
      :retry_base_ms
    ]

    prepared =
      options
      |> Map.put_new(:interval_ms, @default_interval_ms)
      |> Map.put_new(:lease_seconds, @default_lease_seconds)
      |> Map.put_new(:maximum_writes, @default_maximum_writes)
      |> Map.put_new(:minimum_interval_ms, @default_minimum_interval_ms)
      |> Map.put_new(:name, nil)
      |> Map.put_new(:refresh_interval_ms, @default_refresh_interval_ms)
      |> Map.put_new(:retry_base_ms, @default_retry_base_ms)

    if valid_options?(prepared, required, optional) do
      prepared
    else
      raise ArgumentError, "invalid thread-status worker options"
    end
  end

  def options!(_options), do: raise(ArgumentError, "invalid thread-status worker options")

  defp valid_options?(options, required, optional) do
    keys = Map.keys(options)

    Enum.all?([
      keys -- (required ++ optional) == [],
      Enum.all?(required, &(&1 in keys)),
      is_atom(Map.get(options, :api)),
      function_exported?(Map.get(options, :api), :set_thread_status, 4),
      is_function(Map.get(options, :snapshot), 1),
      valid_ref?(Map.get(options, :worker_ref)),
      valid_ref?(Map.get(options, :workspace_ref)),
      Map.get(options, :interval_ms) in 50..3_600_000,
      Map.get(options, :lease_seconds) in 5..3_600,
      Map.get(options, :maximum_writes) in 1..100,
      Map.get(options, :minimum_interval_ms) in 100..60_000,
      Map.get(options, :refresh_interval_ms) in 60_000..110_000,
      Map.get(options, :retry_base_ms) in 100..60_000
    ])
  end

  defp valid_ref?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
        String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch
end
