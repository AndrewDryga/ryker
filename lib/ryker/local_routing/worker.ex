defmodule Ryker.LocalRouting.Worker do
  @moduledoc """
  The one lane that asks the local routing model, one comparison at a time
  (`Ryker.LocalRouting.run_next/1`).

  It runs only while Settings › Models › Local routing model is in shadow
  (`Ryker.Runtime.Assembly`), with the saved endpoint and model; changing
  either restarts it and turning the mode off stops it, leaving any queued
  comparison for when it runs again. A comparison queued by routing wakes it
  at once. With nothing due it sleeps until the next retry falls due, or for
  the safety-net interval.
  """

  use Ryker.PollingWorker, lane: :local_routing, interval: :poll_interval_ms

  require Logger

  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.Endpoint
  alias Ryker.PollingWorker
  alias Ryker.Settings.Work

  @fields [
    :endpoint,
    :model,
    :max_attempts,
    :poll_interval_ms,
    :retry_base_seconds,
    :retry_max_seconds,
    :timeout_ms
  ]
  @optional [:finch, :idle_interval_ms, :name]
  # Coop's own turns may run for an hour; a routing answer that takes longer
  # than ten minutes is no answer to measure.
  @longest_timeout_ms 600_000

  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}}
  end

  def start_link(configuration) do
    options = options!(configuration)
    GenServer.start_link(__MODULE__, options, name: options.name)
  end

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(configuration) when is_map(configuration) or is_list(configuration) do
    configuration = Map.new(configuration)

    unless Enum.all?(@fields, &Map.has_key?(configuration, &1)) and
             Map.keys(configuration) -- (@fields ++ @optional) == [] do
      raise ArgumentError, "local routing configuration has missing or unknown fields"
    end

    case Endpoint.check(configuration.endpoint) do
      :ok ->
        :ok

      {:error, :insecure} ->
        raise ArgumentError,
              "local routing endpoint must use https beyond this machine and private networks"

      {:error, :format} ->
        raise ArgumentError, "local routing endpoint must be one http or https address"
    end

    unless Work.local_model?(configuration.model),
      do: raise(ArgumentError, "local routing model must name one model, without spaces")

    between!(configuration.timeout_ms, 1..@longest_timeout_ms, "timeout_ms")
    between!(configuration.max_attempts, 1..10, "max_attempts")
    between!(configuration.poll_interval_ms, 1..3_600_000, "poll_interval_ms")
    between!(configuration.retry_base_seconds, 1..86_400, "retry_base_seconds")

    between!(
      configuration.retry_max_seconds,
      configuration.retry_base_seconds..86_400,
      "retry_max_seconds"
    )

    idle = Map.get(configuration, :idle_interval_ms, PollingWorker.idle_interval_ms())
    between!(idle, 1..3_600_000, "idle_interval_ms")

    configuration
    |> Map.put(:idle_interval_ms, idle)
    |> Map.put_new(:finch, Ryker.CoopFinch)
    |> Map.put_new(:name, __MODULE__)
  end

  defp between!(value, first..last//1, field) do
    unless is_integer(value) and value >= first and value <= last,
      do:
        raise(
          ArgumentError,
          "local routing #{field} must be a whole number from #{first} to #{last}"
        )
  end

  @impl PollingWorker
  def setup(options), do: {:ok, options}

  @impl PollingWorker
  def wake_on(_state), do: [&LocalRouting.subscribe_comparisons/0]

  @impl PollingWorker
  def poll(state) do
    case LocalRouting.run_next(
           endpoint: state.endpoint,
           finch: state.finch,
           max_attempts: state.max_attempts,
           model: state.model,
           retry_base_seconds: state.retry_base_seconds,
           retry_max_seconds: state.retry_max_seconds,
           timeout_ms: state.timeout_ms
         ) do
      :idle -> PollingWorker.idle_delay(&LocalRouting.next_due_at/1, state.idle_interval_ms)
      {:ran, _comparison} -> 0
    end
  rescue
    # The database's outage is the loop's to wait out (`Ryker.PollingWorker`).
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      reraise error, __STACKTRACE__

    # Anything else is this comparison's problem, never the lane's: its
    # attempt stays counted and fenced, so it is asked again later and given
    # up after its last attempt.
    error ->
      Logger.error("local routing comparison failed: #{inspect(error.__struct__)}")
      state.poll_interval_ms
  end
end
