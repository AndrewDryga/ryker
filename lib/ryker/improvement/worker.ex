defmodule Ryker.Improvement.Worker do
  @moduledoc """
  One slot of the self-analysis pool (`Ryker.Improvement.Runtime`).

  A new candidate, or new feedback on one, is announced
  (`Ryker.Improvement.subscribe_improvement/0`), and so is a request whose
  Work comes to rest (`Ryker.Episodes.subscribe_episodes/0`); each wakes the
  slot at once. With nothing to analyze it sleeps until a candidate's quiet
  time, retry or lease falls due (`Ryker.Improvement.Analyses.next_due_at/2`),
  or for its safety-net interval.
  """
  use Ryker.PollingWorker, lane: :improvement, interval: :poll_interval_ms
  require Logger
  alias Ryker.{Episodes, Improvement, PollingWorker}
  alias Ryker.Improvement.{Analyses, Dispatcher}

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings)

  @impl PollingWorker
  def wake_on(_settings),
    do: [&Improvement.subscribe_improvement/0, &Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def poll(settings) do
    case Dispatcher.run_once(settings) do
      {:ok, :idle} ->
        PollingWorker.idle_delay(
          &Analyses.next_due_at(&1, settings),
          Map.get(settings, :idle_interval_ms, PollingWorker.idle_interval_ms())
        )

      {:ok, _progress} ->
        0

      {:error, reason} ->
        Logger.warning("self-analysis step deferred: #{inspect(reason, limit: 5)}")
        settings.poll_interval_ms
    end
  end
end
