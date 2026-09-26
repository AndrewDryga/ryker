defmodule Ryker.Schedules.ScheduleWorker do
  @moduledoc false

  use Ryker.PollingWorker, lane: :schedule, interval: :poll_interval_ms

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Schedules.ScheduleDispatcher

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl Ryker.PollingWorker
  def setup(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 1_000)
    dispatcher_options = Keyword.fetch!(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms in 1..300_000 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      {:ok, %{dispatcher_options: dispatcher_options, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_schedule_worker, :options}}
    end
  end

  @impl Ryker.PollingWorker
  def poll(state) do
    case ScheduleDispatcher.run_once(state.dispatcher_options) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.error("schedule dispatcher failed: #{inspect(reason)}")
    end

    _ = Progress.beat(:schedule)
    state.poll_interval_ms
  end
end
