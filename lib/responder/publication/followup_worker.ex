defmodule Responder.Publication.FollowupWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Publication.FollowupDispatcher

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 250)
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms > 0 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      send(self(), :poll)
      {:ok, %{dispatcher_options: dispatcher_options, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_publication_followup_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    case FollowupDispatcher.run_once(state.dispatcher_options) do
      {:ok, :idle} ->
        :ok

      {:ok, {:executed, _result}} ->
        :ok

      {:ok, {:deferred, reason}} ->
        Logger.warning("publication followup deferred: #{inspect(reason)}")

      {:error, reason} ->
        Logger.error("publication followup dispatcher failed: #{inspect(reason)}")
    end

    _ = Progress.beat(:publication_followup)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, state}
  end
end
