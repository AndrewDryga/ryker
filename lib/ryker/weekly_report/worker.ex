defmodule Ryker.WeeklyReport.Worker do
  @moduledoc """
  Sends the weekly report when its time comes (`Ryker.WeeklyReport.run_once/1`).

  It runs only while the report is on, has a channel and Slack is connected
  (`Ryker.Runtime.Assembly`): a report that is off has no worker, so it
  writes nothing and logs nothing. It checks once when it starts, which
  sends a report Ryker was down for, then sleeps until the next send time. A
  settings save is announced after it commits and wakes it at once
  (`Ryker.Settings.subscribe/0`), so a new day, time or zone takes effect
  without waiting. It never sleeps longer than `:longest_sleep_ms`, so a
  host that was suspended past the send time notices soon after it wakes.

  Posting is not its job: it queues the week's report, and the delivery pool
  posts it (`Ryker.WeeklyReport.Custody`).
  """
  use Ryker.PollingWorker, lane: :weekly_report, interval: :retry_ms
  alias Ryker.{Options, PollingWorker, Settings, WeeklyReport}
  require Logger

  @fields [:longest_sleep_ms, :retry_ms]
  @longest_sleep_ms 600_000
  @retry_ms 60_000

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}}
  end

  def start_link(configuration),
    do: GenServer.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl PollingWorker
  def setup(configuration), do: {:ok, options!(configuration)}

  @impl PollingWorker
  def wake_on(_options), do: [&Settings.subscribe/0]

  @impl PollingWorker
  def poll(options) do
    case WeeklyReport.run_once() do
      {:ok, :off} ->
        options.longest_sleep_ms

      {:ok, {:waiting, next_at}} ->
        PollingWorker.idle_delay(fn _since -> next_at end, options.longest_sleep_ms)

      {:ok, {:queued, report, next_at}} ->
        Logger.info("weekly report queued for the week of #{report.week}")
        PollingWorker.idle_delay(fn _since -> next_at end, options.longest_sleep_ms)

      {:error, reason} ->
        Logger.warning("weekly report not queued: #{inspect(reason, limit: 5)}")
        options.retry_ms
    end
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    options =
      Options.normalize!(configuration, @fields, [],
        list: "weekly report configuration must use unique known fields",
        map: "weekly report configuration has unknown fields",
        other: "weekly report configuration must be a map or keyword list"
      )

    options = Map.merge(%{longest_sleep_ms: @longest_sleep_ms, retry_ms: @retry_ms}, options)

    unless Enum.all?(@fields, &(is_integer(options[&1]) and options[&1] > 0)),
      do: raise(ArgumentError, "weekly report configuration is outside its safe bounds")

    options
  end
end
