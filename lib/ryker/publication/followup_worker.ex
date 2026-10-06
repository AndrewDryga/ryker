defmodule Ryker.Publication.FollowupWorker do
  @moduledoc """
  Polls published pull requests and delivers their lifecycle notices.

  A publication, its follow-up or a lifecycle notice that changes is
  announced, and that wakes the worker at once. Otherwise it sleeps until the
  next poll, retry or unrenewed lease falls due, or for its safety-net
  interval.
  """

  use Ryker.PollingWorker, lane: :publication_followup, interval: :poll_interval_ms
  require Logger
  alias Ryker.Observability.Progress
  alias Ryker.PollingWorker
  alias Ryker.Publication.{Custody, FollowupDispatcher}

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl PollingWorker
  def setup(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 250)
    idle_interval_ms = Keyword.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if positive?(poll_interval_ms) and positive?(idle_interval_ms) and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      {:ok,
       %{
         dispatcher_options: dispatcher_options,
         idle_interval_ms: idle_interval_ms,
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_publication_followup_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Custody.subscribe_publications/0]

  @impl PollingWorker
  def poll(state) do
    delay =
      case FollowupDispatcher.run_once(state.dispatcher_options) do
        {:ok, :idle} ->
          PollingWorker.idle_delay(
            &FollowupDispatcher.next_due_at(state.dispatcher_options, &1),
            state.idle_interval_ms
          )

        {:ok, {:executed, _result}} ->
          0

        {:ok, {:deferred, reason}} ->
          Logger.warning("publication followup deferred: #{inspect(reason)}")
          0

        {:error, reason} ->
          Logger.error("publication followup dispatcher failed: #{inspect(reason)}")
          state.poll_interval_ms
      end

    _ = Progress.beat(:publication_followup)
    delay
  end

  defp positive?(value), do: is_integer(value) and value > 0
end
