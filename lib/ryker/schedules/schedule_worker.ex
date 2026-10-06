defmodule Ryker.Schedules.ScheduleWorker do
  @moduledoc """
  Starts each schedule's occurrence when it falls due.

  A schedule that is confirmed, paused, resumed, run or changed is announced,
  and that wakes the worker at once. Otherwise it sleeps until the next
  occurrence, retry or unrenewed lease falls due, or for its safety-net
  interval.
  """

  use Ryker.PollingWorker, lane: :schedule, interval: :poll_interval_ms
  require Logger
  alias Ryker.Observability.Progress
  alias Ryker.PollingWorker
  alias Ryker.Schedules
  alias Ryker.Schedules.ScheduleDispatcher

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl PollingWorker
  def setup(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 1_000)
    idle_interval_ms = Keyword.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
    dispatcher_options = Keyword.fetch!(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms in 1..300_000 and
         is_integer(idle_interval_ms) and idle_interval_ms > 0 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      {:ok,
       %{
         dispatcher_options: dispatcher_options,
         idle_interval_ms: idle_interval_ms,
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_schedule_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Schedules.subscribe_schedules/0]

  @impl PollingWorker
  def poll(state) do
    delay =
      case ScheduleDispatcher.run_once(state.dispatcher_options) do
        {:ok, :idle} ->
          PollingWorker.idle_delay(
            &ScheduleDispatcher.next_due_at(state.dispatcher_options, &1),
            state.idle_interval_ms
          )

        {:ok, _result} ->
          0

        {:error, reason} ->
          Logger.error("schedule dispatcher failed: #{inspect(reason)}")
          state.poll_interval_ms
      end

    _ = Progress.beat(:schedule)
    delay
  end
end
