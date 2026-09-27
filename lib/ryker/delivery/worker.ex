defmodule Ryker.Delivery.Worker do
  @moduledoc """
  Polls one durable delivery phase from a bounded local worker pool.

  PostgreSQL leases remain the durable owner. This process can crash or restart
  without changing the frozen platform request.

  Whatever queues or releases a delivery of its kind is announced, and that
  wakes the worker at once (`Ryker.Delivery.Dispatcher.subscriptions/1`). With
  nothing to send it sleeps until the next retry or unrenewed lease falls due,
  or for its safety-net interval.
  """

  use Ryker.PollingWorker, lane: :delivery, interval: :poll_interval_ms

  require Logger

  alias Ryker.Delivery.Dispatcher
  alias Ryker.Observability.Progress
  alias Ryker.PollingWorker

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
         kind: Keyword.get(dispatcher_options, :kind),
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_delivery_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(state), do: Dispatcher.subscriptions(state.kind)

  @impl PollingWorker
  def poll(state) do
    delay = process_once(state)
    _ = Progress.beat(:delivery)
    delay
  end

  defp process_once(state) do
    case Dispatcher.run_once(state.dispatcher_options) do
      {:ok, :idle} ->
        PollingWorker.idle_delay(&Dispatcher.next_due_at(state.kind, &1), state.idle_interval_ms)

      {:ok, {:delivered, _kind, _delivery_ref}} ->
        0

      {:ok, {:deferred, kind, delivery_ref, reason}} ->
        Logger.warning("#{kind} delivery #{delivery_ref} deferred: #{inspect(reason)}")
        0

      {:ok, {:blocked, kind, delivery_ref, reason}} ->
        Logger.error("#{kind} delivery #{delivery_ref} blocked: #{inspect(reason)}")
        0

      {:error, reason} ->
        Logger.error("delivery dispatcher failed: #{inspect(reason)}")
        state.poll_interval_ms
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0
end
