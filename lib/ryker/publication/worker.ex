defmodule Ryker.Publication.Worker do
  @moduledoc false

  use Ryker.PollingWorker, lane: :publication, interval: :poll_interval_ms

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Publication.Dispatcher

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
      {:stop, {:invalid_publication_worker, :options}}
    end
  end

  @impl Ryker.PollingWorker
  def poll(state) do
    process_once(state.dispatcher_options)
    _ = Progress.beat(:publication)
    state.poll_interval_ms
  end

  defp process_once(options) do
    case Dispatcher.run_once(options) do
      {:ok, :idle} -> :ok
      {:ok, {:executed, _result}} -> :ok
      {:ok, {:deferred, reason}} -> Logger.warning("publication deferred: #{inspect(reason)}")
      {:ok, {:discarded, reason}} -> Logger.info("publication discarded: #{inspect(reason)}")
      {:error, reason} -> Logger.error("publication dispatcher failed: #{inspect(reason)}")
    end
  end
end
