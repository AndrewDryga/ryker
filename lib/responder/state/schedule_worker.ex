defmodule Responder.State.ScheduleWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Polling
  alias Responder.State.ScheduleDispatcher

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl GenServer
  def init(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 1_000)
    dispatcher_options = Keyword.fetch!(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms in 1..300_000 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      send(self(), :poll)
      {:ok, %{dispatcher_options: dispatcher_options, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_schedule_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:schedule, state.poll_interval_ms, fn ->
        case ScheduleDispatcher.run_once(state.dispatcher_options) do
          {:ok, _result} -> :ok
          {:error, reason} -> Logger.error("schedule dispatcher failed: #{inspect(reason)}")
        end

        _ = Progress.beat(:schedule)
        state.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end
end
