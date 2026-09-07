defmodule Responder.Delivery.Worker do
  @moduledoc """
  Polls one durable delivery phase from a bounded local worker pool.

  PostgreSQL leases remain the durable owner. This process can crash or restart
  without changing the frozen platform request.
  """

  use GenServer

  require Logger

  alias Responder.Delivery.Dispatcher
  alias Responder.Observability.Progress
  alias Responder.Polling

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)

    if name,
      do: GenServer.start_link(__MODULE__, options, name: name),
      else: GenServer.start_link(__MODULE__, options)
  end

  @impl GenServer
  def init(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 250)
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms > 0 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      send(self(), :poll)
      {:ok, %{dispatcher_options: dispatcher_options, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_delivery_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:delivery, state.poll_interval_ms, fn ->
        process_once(state.dispatcher_options)
        _ = Progress.beat(:delivery)
        state.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
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
