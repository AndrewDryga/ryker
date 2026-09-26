defmodule Ryker.Learning.Worker do
  @moduledoc false
  use Ryker.PollingWorker, lane: :learning, interval: :poll_interval_ms
  require Logger
  alias Ryker.Learning.Dispatcher
  alias Ryker.Observability.Progress

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings)

  @impl Ryker.PollingWorker
  def poll(settings) do
    case Dispatcher.run_once(settings) do
      {:ok, _} ->
        Progress.beat(:learning)

      {:error, _reason} ->
        Progress.beat(:learning, :error)
        Logger.warning("learning dispatch deferred; inspect the durable learning receipt")
    end

    settings.poll_interval_ms
  end
end
