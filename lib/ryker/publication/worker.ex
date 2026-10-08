defmodule Ryker.Publication.Worker do
  @moduledoc """
  One slot of the publication pool: reviews, their delivery and draft pull
  requests.

  A publication that changes is announced, and so is a request whose Work
  turn ends, which is what a requested review waits for; either wakes the
  slot at once. With nothing to do it sleeps until a retry or an unrenewed
  lease falls due, or for its safety-net interval.
  """
  use Ryker.PollingWorker, lane: :publication, interval: :poll_interval_ms
  alias Ryker.Episodes
  alias Ryker.Observability
  alias Ryker.PollingWorker
  alias Ryker.Publication.{Custody, Dispatcher}
  require Logger

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
      {:stop, {:invalid_publication_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Custody.subscribe_publications/0, &Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def poll(state) do
    delay = process_once(state)
    _ = Observability.Progress.beat(:publication)
    delay
  end

  defp process_once(state) do
    case Dispatcher.run_once(state.dispatcher_options) do
      {:ok, :idle} ->
        PollingWorker.idle_delay(&Custody.next_due_at/1, state.idle_interval_ms)

      {:ok, {:executed, _result}} ->
        0

      {:ok, {:deferred, reason}} ->
        Logger.warning("publication deferred: #{inspect(reason)}")
        0

      {:ok, {:discarded, reason}} ->
        Logger.info("publication discarded: #{inspect(reason)}")
        0

      {:ok, {:lease_lost, _reason}} ->
        Logger.info("publication attempt ended: it was discarded or taken over while it ran")
        0

      {:error, reason} ->
        Logger.error("publication dispatcher failed: #{inspect(reason)}")
        state.poll_interval_ms
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0
end
