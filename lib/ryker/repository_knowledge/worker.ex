defmodule Ryker.RepositoryKnowledge.Worker do
  @moduledoc """
  The one slot of the knowledge lane (`Ryker.RepositoryKnowledge.Runtime`).

  A repository set up, refreshed from the Repositories page, or written a
  step further is announced (`Ryker.RepositoryKnowledge.subscribe/0`), and
  so is every settings save, which is how a repository is added, set up or
  removed (`Ryker.Settings.subscribe/0`); each wakes the slot at once. With
  nothing to do it sleeps until a repository's check, retry or lease falls
  due (`Ryker.RepositoryKnowledge.Dispatcher.next_due_at/1`), or for its
  safety-net interval.
  """
  use Ryker.PollingWorker, lane: :repository_knowledge, interval: :poll_interval_ms
  require Logger
  alias Ryker.{PollingWorker, RepositoryKnowledge, Settings}
  alias Ryker.RepositoryKnowledge.Dispatcher

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings)

  @impl PollingWorker
  def wake_on(_settings), do: [&RepositoryKnowledge.subscribe/0, &Settings.subscribe/0]

  @impl PollingWorker
  def poll(settings) do
    case Dispatcher.run_once(settings) do
      {:ok, :idle} ->
        PollingWorker.idle_delay(
          &Dispatcher.next_due_at/1,
          Map.get(settings, :idle_interval_ms, PollingWorker.idle_interval_ms())
        )

      {:ok, _progress} ->
        0

      {:error, reason} ->
        Logger.warning("repository knowledge step deferred: #{inspect(reason, limit: 5)}")
        settings.poll_interval_ms
    end
  end
end
