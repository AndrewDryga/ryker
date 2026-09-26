defmodule Ryker.State.EventWaitWorker do
  @moduledoc false

  use Ryker.PollingWorker, lane: :event_waits, interval: :interval_ms

  require Logger

  alias Ryker.Observability.Progress
  alias Ryker.Options
  alias Ryker.State.EventWaits

  @invalid_interval "event wait poll_interval_ms must be positive"

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, interval!(options), name: __MODULE__)
  end

  @impl Ryker.PollingWorker
  def setup(interval_ms), do: {:ok, %{interval_ms: interval_ms}}

  @impl Ryker.PollingWorker
  def poll(state) do
    case EventWaits.resume_due() do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.error("event wait wakeup failed: #{inspect(reason)}")
    end

    _ = Progress.beat(:event_waits)
    state.interval_ms
  end

  defp interval!(options) do
    value =
      options
      |> Options.normalize!([:poll_interval_ms], [], @invalid_interval)
      |> Map.get(:poll_interval_ms, 1_000)

    if is_integer(value) and value > 0 and value <= 300_000,
      do: value,
      else: raise(ArgumentError, @invalid_interval)
  end
end
