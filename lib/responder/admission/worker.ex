defmodule Responder.Admission.Worker do
  @moduledoc """
  Small polling loop for the durable admission inbox.

  Multiple workers may share the database; inbox leases prevent duplicate
  ownership. A process crash leaves the input claimable after its lease expires.
  """

  use GenServer

  require Logger

  alias Responder.Admission.Dispatcher
  alias Responder.Observability.Progress

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
      {:stop, {:invalid_admission_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay = process_once(state.dispatcher_options, state.poll_interval_ms)
    _ = Progress.beat(:admission)
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp process_once(options, idle_delay) do
    case Dispatcher.run_once(options) do
      {:ok, :idle} ->
        idle_delay

      {:ok, {:decided, _execution}} ->
        0

      {:ok, {:deferred, input_ref, reason}} ->
        Logger.warning("admission input #{input_ref} deferred: #{inspect(reason)}")
        0

      {:ok, {:blocked, input_ref, reason}} ->
        Logger.warning("admission input #{input_ref} blocked: #{inspect(reason)}")
        0

      {:error, reason} ->
        Logger.error("admission dispatcher failed: #{inspect(reason)}")
        idle_delay
    end
  end
end
