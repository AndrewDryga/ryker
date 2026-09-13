defmodule Ryker.Emisar.ApprovalWorker do
  @moduledoc false

  use GenServer

  require Logger

  alias Ryker.Emisar.ApprovalDispatcher
  alias Ryker.Observability.Progress
  alias Ryker.Polling

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)

    if name,
      do: GenServer.start_link(__MODULE__, options, name: name),
      else: GenServer.start_link(__MODULE__, options)
  end

  @impl GenServer
  def init(options) do
    poll_interval_ms = Keyword.get(options, :poll_interval_ms, 1_000)
    dispatcher_options = Keyword.get(options, :dispatcher_options)

    if is_integer(poll_interval_ms) and poll_interval_ms in 1..300_000 and
         is_list(dispatcher_options) and Keyword.keyword?(dispatcher_options) do
      send(self(), :poll)
      {:ok, %{dispatcher_options: dispatcher_options, poll_interval_ms: poll_interval_ms}}
    else
      {:stop, {:invalid_emisar_approval_worker, :options}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    delay =
      Polling.run(:emisar_approval, state.poll_interval_ms, fn ->
        process_once(state.dispatcher_options)
        _ = Progress.beat(:emisar_approval)
        state.poll_interval_ms
      end)

    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp process_once(options) do
    case ApprovalDispatcher.run_once(options) do
      {:ok, :idle} ->
        :ok

      {:ok, {:monitoring, _request_id, _status}} ->
        :ok

      {:ok, {:resumed, _request_id, _status}} ->
        :ok

      {:ok, {:deferred, request_id, reason}} ->
        Logger.warning("Emisar approval #{request_id} deferred: #{inspect(reason)}")

      {:ok, {:blocked, request_id, reason}} ->
        Logger.error("Emisar approval #{request_id} blocked: #{inspect(reason)}")

      {:error, reason} ->
        Logger.error("Emisar approval dispatcher failed: #{inspect(reason)}")
    end
  end
end
