defmodule Responder.Publication.Worker do
  @moduledoc false

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Polling
  alias Responder.Publication.Dispatcher

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
      {:stop, {:invalid_publication_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:publication, state.poll_interval_ms, fn ->
        process_once(state.dispatcher_options)
        _ = Progress.beat(:publication)
        state.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp process_once(options) do
    case Dispatcher.run_once(options) do
      {:ok, :idle} -> :ok
      {:ok, {:executed, _result}} -> :ok
      {:ok, {:deferred, reason}} -> Logger.warning("publication deferred: #{inspect(reason)}")
      {:error, reason} -> Logger.error("publication dispatcher failed: #{inspect(reason)}")
    end
  end
end
