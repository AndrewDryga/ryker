defmodule Ryker.Slack.MonitoringWorker do
  @moduledoc "Reconciles monitoring receipts on episode changes and after restart."
  use Ryker.PollingWorker, lane: :slack_monitoring, interval: :interval_ms
  alias Ryker.Episodes
  alias Ryker.PollingWorker
  alias Ryker.Slack.Monitoring
  require Logger

  def start_link(_options),
    do: GenServer.start_link(__MODULE__, %{interval_ms: 60_000, checked_at: nil})

  @impl PollingWorker
  def wake_on(_state), do: [&Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def woken({:episode_updated, id}, _state), do: report(Monitoring.reconcile_episode(id))
  def woken(_message, _state), do: :ok

  @impl PollingWorker
  def poll(state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(state.checked_at) or now - state.checked_at >= state.interval_ms do
      report(Monitoring.reconcile())
      {state.interval_ms, %{state | checked_at: now}}
    else
      state.interval_ms - (now - state.checked_at)
    end
  end

  defp report(:ok), do: :ok

  defp report({:error, reason}),
    do: Logger.warning("Slack monitoring refresh failed: #{inspect(reason)}")
end
