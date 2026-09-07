defmodule Responder.State.EventWaitWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias Responder.Observability.Progress
  alias Responder.Polling
  alias Responder.State.EventWaits

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, interval!(options), name: __MODULE__)
  end

  @impl GenServer
  def init(interval_ms) do
    send(self(), :poll)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:event_waits, state.interval_ms, fn ->
        case EventWaits.resume_due() do
          {:ok, _result} -> :ok
          {:error, reason} -> Logger.error("event wait wakeup failed: #{inspect(reason)}")
        end

        _ = Progress.beat(:event_waits)
        state.interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp interval!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> interval!(),
      else: invalid!()
  end

  defp interval!(%{} = options) do
    if Map.keys(options) -- [:poll_interval_ms] == [] do
      value = Map.get(options, :poll_interval_ms, 1_000)

      if is_integer(value) and value > 0 and value <= 300_000,
        do: value,
        else: invalid!()
    else
      invalid!()
    end
  end

  defp interval!(_options), do: invalid!()

  defp invalid!, do: raise(ArgumentError, "event wait poll_interval_ms must be positive")
end
