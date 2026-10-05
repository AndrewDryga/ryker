defmodule Ryker.Work.Worker do
  @moduledoc """
  Small polling loop for one slot in the local episode-work pool.

  PostgreSQL custody, rather than this process, is the durable owner. A crash
  leaves work claimable after its fenced lease expires.

  Every change that can make work claimable is announced on its request's
  topics, and that wakes the slot at once. With nothing to take it sleeps
  until the next retry, polling window or unrenewed lease falls due, or for
  its safety-net interval.
  """

  use Ryker.PollingWorker, lane: :work, interval: :poll_interval_ms

  require Logger

  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.Observability.Progress
  alias Ryker.PollingWorker
  alias Ryker.Work.{Custody, Dispatcher}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl PollingWorker
  def setup(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 250)
    idle_interval_ms = Keyword.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if positive?(poll_interval_ms) and positive?(idle_interval_ms) and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      {:ok,
       %{
         dispatcher_options: dispatcher_options,
         idle_interval_ms: idle_interval_ms,
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_work_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def poll(state) do
    delay = process_once(state)
    _ = Progress.beat(:work)
    delay
  end

  defp process_once(state) do
    case Dispatcher.run_once(state.dispatcher_options) do
      {:ok, :idle} ->
        PollingWorker.idle_delay(&Custody.next_due_at(&1, :work), state.idle_interval_ms)

      {:ok, {:executed, _execution}} ->
        0

      {:ok, {:deferred, reason}} ->
        Logger.warning("episode work deferred: #{ErrorDetail.detail(reason)}")
        0

      {:ok, {:blocked, reason}} ->
        Logger.warning("episode work blocked: #{ErrorDetail.detail(reason)}")
        0

      {:error, reason} ->
        Logger.error("episode work dispatcher failed: #{ErrorDetail.detail(reason)}")
        state.poll_interval_ms
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0
end
