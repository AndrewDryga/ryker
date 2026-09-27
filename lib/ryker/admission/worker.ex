defmodule Ryker.Admission.Worker do
  @moduledoc """
  Small polling loop for the durable admission inbox.

  Multiple workers may share the database; inbox leases prevent duplicate
  ownership. A process crash leaves the input claimable after its lease expires.

  The inbox announces every message it records or releases, and that wakes the
  loop at once. With nothing to route it sleeps until the next retry or
  unrenewed lease falls due, or for its safety-net interval.
  """

  use Ryker.PollingWorker, lane: :admission, interval: :poll_interval_ms

  require Logger

  alias Ryker.Admission.Dispatcher
  alias Ryker.Ingress.Inbox
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
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_admission_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Inbox.subscribe_inputs/0]

  @impl PollingWorker
  def poll(state) do
    delay = process_once(state)
    _ = Progress.beat(:admission)
    delay
  end

  defp process_once(state) do
    case Dispatcher.run_once(state.dispatcher_options) do
      {:ok, :idle} ->
        PollingWorker.idle_delay(
          &Inbox.next_due_at/1,
          state.poll_interval_ms,
          state.idle_interval_ms
        )

      {:ok, {:decided, _execution}} ->
        0

      {:ok, {:deferred, input_ref, reason}} ->
        Logger.warning("admission input #{input_ref} deferred: #{inspect(reason)}")
        0

      {:ok, {:blocked, input_ref, reason}} ->
        Logger.warning("admission input #{input_ref} blocked: #{inspect(reason)}")
        0

      {:ok, {:closed, input_ref, reason}} ->
        Logger.info("admission input #{input_ref} closed unread: #{inspect(reason)}")
        0

      {:error, reason} ->
        Logger.error("admission dispatcher failed: #{inspect(reason)}")
        state.poll_interval_ms
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0
end
