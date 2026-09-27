defmodule Ryker.Learning.Worker do
  @moduledoc """
  One slot of the learning pool.

  A routed message and a batch that changes are announced, and each wakes the
  slot at once. With nothing to learn it sleeps until a conversation has been
  quiet long enough or a batch's retry or lease falls due
  (`Ryker.Learning.Batches.next_due_at/2`), or for its safety-net interval.
  """
  use Ryker.PollingWorker, lane: :learning, interval: :poll_interval_ms
  require Logger
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning
  alias Ryker.Learning.{Batches, Dispatcher}
  alias Ryker.Observability.Progress
  alias Ryker.PollingWorker

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings)

  @impl PollingWorker
  def wake_on(_settings), do: [&Inbox.subscribe_inputs/0, &Learning.subscribe_learning/0]

  @impl PollingWorker
  def poll(settings) do
    case Dispatcher.run_once(settings) do
      {:ok, :idle} ->
        Progress.beat(:learning)

        PollingWorker.idle_delay(
          &Batches.next_due_at(&1, settings),
          Map.get(settings, :idle_interval_ms, PollingWorker.idle_interval_ms())
        )

      {:ok, _} ->
        Progress.beat(:learning)
        0

      {:error, _reason} ->
        Progress.beat(:learning, :error)
        Logger.warning("learning dispatch deferred; inspect the durable learning receipt")
        settings.poll_interval_ms
    end
  end
end
