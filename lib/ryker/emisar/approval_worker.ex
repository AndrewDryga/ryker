defmodule Ryker.Emisar.ApprovalWorker do
  @moduledoc """
  One slot watching an Emisar account's approval-bound runs.

  A watch that is registered or changes, and a task that starts or stops
  waiting for one, are announced, and each wakes the slot at once. Otherwise
  it sleeps until a watch's next look at Emisar or a retry falls due, or for
  its safety-net interval.
  """

  use Ryker.PollingWorker, lane: :emisar_approval, interval: :poll_interval_ms
  require Logger
  alias Ryker.Emisar.{ApprovalDispatcher, Approvals}
  alias Ryker.Episodes
  alias Ryker.Observability.Progress
  alias Ryker.PollingWorker

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl PollingWorker
  def setup(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 1_000)
    idle_interval_ms = Keyword.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms())
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms in 1..300_000 and
         is_integer(idle_interval_ms) and idle_interval_ms > 0 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      {:ok,
       %{
         dispatcher_options: dispatcher_options,
         idle_interval_ms: idle_interval_ms,
         poll_interval_ms: poll_interval_ms
       }}
    else
      {:stop, {:invalid_emisar_approval_worker, :options}}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Approvals.subscribe_approvals/0, &Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def poll(state) do
    delay = process_once(state)
    _ = Progress.beat(:emisar_approval)
    delay
  end

  defp process_once(state) do
    case ApprovalDispatcher.run_once(state.dispatcher_options) do
      {:ok, :idle} ->
        idle_delay(state)

      {:ok, {:closed, request_ids}} ->
        Logger.info(
          "Emisar approvals closed because no task waits for them: #{Enum.join(request_ids, ", ")}"
        )

        0

      {:ok, {:monitoring, _request_id, _status}} ->
        0

      {:ok, {:resumed, _request_id, _status}} ->
        0

      {:ok, {:deferred, request_id, reason}} ->
        Logger.warning("Emisar approval #{request_id} deferred: #{inspect(reason)}")
        0

      {:ok, {:blocked, request_id, reason}} ->
        Logger.error("Emisar approval #{request_id} blocked: #{inspect(reason)}")
        0

      {:error, reason} ->
        Logger.error("Emisar approval dispatcher failed: #{inspect(reason)}")
        state.poll_interval_ms
    end
  end

  defp idle_delay(state) do
    connection_ref = Keyword.fetch!(state.dispatcher_options, :connection_ref)
    PollingWorker.idle_delay(&Approvals.next_due_at(connection_ref, &1), state.idle_interval_ms)
  end
end
