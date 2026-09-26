defmodule Ryker.Work.Worker do
  @moduledoc """
  Small polling loop for one slot in the local episode-work pool.

  PostgreSQL custody, rather than this process, is the durable owner. A crash
  leaves work claimable after its fenced lease expires.
  """

  use Ryker.PollingWorker, lane: :work, interval: :poll_interval_ms

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Work.Dispatcher

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl Ryker.PollingWorker
  def setup(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 250)
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms > 0 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      {:ok, %{dispatcher_options: dispatcher_options, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_work_worker, :options}}
    end
  end

  @impl Ryker.PollingWorker
  def poll(state) do
    delay = process_once(state.dispatcher_options, state.poll_interval_ms)
    _ = Progress.beat(:work)
    delay
  end

  defp process_once(options, idle_delay) do
    case Dispatcher.run_once(options) do
      {:ok, :idle} ->
        idle_delay

      {:ok, {:executed, _execution}} ->
        idle_delay

      {:ok, {:deferred, reason}} ->
        Logger.warning("episode work deferred: #{inspect(reason)}")
        idle_delay

      {:ok, {:blocked, reason}} ->
        Logger.warning("episode work blocked: #{inspect(reason)}")
        idle_delay

      {:error, reason} ->
        Logger.error("episode work dispatcher failed: #{inspect(reason)}")
        idle_delay
    end
  end
end
