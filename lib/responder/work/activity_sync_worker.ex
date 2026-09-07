defmodule Responder.Work.ActivitySyncWorker do
  @moduledoc """
  Retries direct-Coop activity reads that failed after a turn had already ended.

  The answer remains deliverable; PostgreSQL's pending bit makes the missing
  narration resumable across an ordinary Responder restart.
  """

  use GenServer

  require Logger

  alias Responder.Polling
  alias Responder.Work.Activity

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl GenServer
  def init(options) do
    api = Keyword.get(options, :api)
    client = Keyword.get(options, :client)
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 250)

    if is_atom(api) and is_integer(poll_interval_ms) and poll_interval_ms > 0 do
      send(self(), :poll)
      {:ok, %{api: api, client: client, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_activity_sync_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:activity_sync, state.poll_interval_ms, fn ->
        case Activity.retry_once(state.api, state.client) do
          {:ok, _result} -> :ok
          {:error, reason} -> Logger.warning("Coop activity sync deferred: #{inspect(reason)}")
        end

        state.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end
end
