defmodule Ryker.Delivery.Worker do
  @moduledoc """
  Polls one durable delivery phase from a bounded local worker pool.

  PostgreSQL leases remain the durable owner. This process can crash or restart
  without changing the frozen platform request.
  """

  use Ryker.PollingWorker, lane: :delivery, interval: :poll_interval_ms

  require Logger

  alias Ryker.Delivery.Dispatcher
  alias Ryker.Observability.Progress

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
      {:stop, {:invalid_delivery_worker, :options}}
    end
  end

  @impl Ryker.PollingWorker
  def poll(state) do
    process_once(state.dispatcher_options)
    _ = Progress.beat(:delivery)
    state.poll_interval_ms
  end

  defp process_once(options) do
    case Dispatcher.run_once(options) do
      {:ok, :idle} ->
        :ok

      {:ok, {:delivered, _kind, _delivery_ref}} ->
        :ok

      {:ok, {:deferred, kind, delivery_ref, reason}} ->
        Logger.warning("#{kind} delivery #{delivery_ref} deferred: #{inspect(reason)}")

      {:ok, {:blocked, kind, delivery_ref, reason}} ->
        Logger.error("#{kind} delivery #{delivery_ref} blocked: #{inspect(reason)}")

      {:error, reason} ->
        Logger.error("delivery dispatcher failed: #{inspect(reason)}")
    end
  end
end
