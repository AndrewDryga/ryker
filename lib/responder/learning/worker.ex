defmodule Responder.Learning.Worker do
  @moduledoc false
  use GenServer
  require Logger
  alias Responder.Learning.Dispatcher
  alias Responder.Observability.Progress

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings)
  @impl true
  def init(settings) do
    send(self(), :poll)
    {:ok, settings}
  end

  @impl true
  def handle_info(:poll, settings) do
    delay =
      Responder.Polling.run(:learning, settings.poll_interval_ms, fn ->
        case Dispatcher.run_once(settings) do
          {:ok, _} ->
            Progress.beat(:learning)

          {:error, _reason} ->
            Progress.beat(:learning, :error)
            Logger.warning("learning dispatch deferred; inspect the durable learning receipt")
        end

        settings.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, settings}
  end
end
