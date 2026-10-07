defmodule Ryker.Waits.EventWaitWorker do
  @moduledoc """
  Resumes each durable event wait when its timer, polling fallback or hard
  deadline falls due.

  A wait that starts or ends, and a follow-up that changes, are announced, and
  each wakes the worker at once to reconcile them. Otherwise it sleeps until
  the next wait falls due (`Ryker.Waits.EventWaits.next_due_at/1`), or for its
  safety-net interval.
  """
  use Ryker.PollingWorker, lane: :event_waits, interval: :interval_ms
  alias Ryker.Episodes
  alias Ryker.Observability.Progress
  alias Ryker.Options
  alias Ryker.PollingWorker
  alias Ryker.Waits.{EventSubscriptions, EventWaits}
  require Logger

  @invalid_interval "event wait poll_interval_ms must be positive"

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, intervals!(options), name: __MODULE__)
  end

  @impl PollingWorker
  def setup({interval_ms, idle_interval_ms}),
    do: {:ok, %{idle_interval_ms: idle_interval_ms, interval_ms: interval_ms}}

  @impl PollingWorker
  def wake_on(_state),
    do: [&EventSubscriptions.subscribe_follow_ups/0, &Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def poll(state) do
    delay =
      case EventWaits.resume_due() do
        {:ok, :idle} ->
          PollingWorker.idle_delay(&EventWaits.next_due_at/1, state.idle_interval_ms)

        {:ok, _resumed} ->
          0

        {:error, reason} ->
          Logger.error("event wait wakeup failed: #{inspect(reason)}")
          state.interval_ms
      end

    _ = Progress.beat(:event_waits)
    delay
  end

  defp intervals!(options) do
    options =
      Options.normalize!(options, [:idle_interval_ms, :poll_interval_ms], [], @invalid_interval)

    value = Map.get(options, :poll_interval_ms, 1_000)
    idle = Map.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())

    if is_integer(value) and value > 0 and value <= 300_000 and is_integer(idle) and idle > 0,
      do: {value, idle},
      else: raise(ArgumentError, @invalid_interval)
  end
end
