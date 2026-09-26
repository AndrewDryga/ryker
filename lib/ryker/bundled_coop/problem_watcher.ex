defmodule Ryker.BundledCoop.ProblemWatcher do
  @moduledoc """
  Tells open pages when the bundled worker's policy problem appears, changes
  or clears.

  When Coop refuses Ryker's newest policies, the worker keeps running the ones
  it loaded before and leaves Coop's reason in the directory it shares with
  Ryker (`Ryker.BundledCoop.policy_problem/0`); Settings › Models says so. Open
  pages redraw every few seconds on their own. This checks the reason as often
  as the worker checks its policies and broadcasts a change the moment it sees
  one, on the topic the Slack names cache uses. It runs only in the Compose
  distribution.
  """
  use GenServer

  alias Ryker.BundledCoop

  @interval_ms 2_000

  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))

  @impl true
  def init(options) do
    state = %{interval_ms: Keyword.get(options, :interval_ms, @interval_ms), seen: read()}
    {:ok, schedule(state)}
  end

  @impl true
  def handle_info(:check, state) do
    seen = read()

    if seen != state.seen,
      do: Phoenix.PubSub.broadcast(Ryker.PubSub, "control-plane", :control_plane_changed)

    {:noreply, schedule(%{state | seen: seen})}
  end

  defp schedule(state) do
    Process.send_after(self(), :check, state.interval_ms)
    state
  end

  defp read do
    BundledCoop.policy_problem_text()
  rescue
    _error -> nil
  end
end
