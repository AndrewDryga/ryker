defmodule Ryker.ControlPlane.WorkerLiveness do
  @moduledoc """
  Tells open pages when a Coop worker stops reporting.

  A worker that stops polling writes nothing, so no commit announces it: its
  heartbeat only grows old, and after a minute the fleet counts it stale
  (`Ryker.Observability.Fleet`). This is the one clock behind the pages that
  show whether a worker is reporting. Every few seconds it asks the fleet
  which workers went quiet since it last asked
  (`Ryker.CoopFleet.ControlPlane.Workers.announce_quiet/1`), which announces
  each one on the workers' topic. A worker that comes back is announced by
  its own first poll.

  It runs beside the console (`Ryker.Runtime.Owner`), since only open pages
  listen.
  """
  use GenServer
  require Logger

  alias Ryker.CoopFleet.ControlPlane.Workers

  @interval_ms 10_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    interval = Keyword.get(options, :interval_ms, @interval_ms)
    {:ok, schedule(%{interval: interval, reporting: MapSet.new()})}
  end

  @impl true
  def handle_info(:check, state) do
    {:noreply, schedule(%{state | reporting: Workers.announce_quiet(state.reporting)})}
  rescue
    # The database will answer again; the workers that went quiet meanwhile
    # are still missing from the set the next check compares against.
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("Worker liveness not checked category=#{inspect(error.__struct__)}")
      {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :check, state.interval)
    state
  end
end
