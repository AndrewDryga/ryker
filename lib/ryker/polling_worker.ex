defmodule Ryker.PollingWorker do
  @moduledoc """
  The one loop every timer-driven poller runs.

  A polling worker polls once as soon as it starts, then again after the delay
  its last cycle returned: nothing when more work is waiting, its configured
  interval when it went idle. A database outage inside a cycle waits for the
  next poll instead of restarting the process.

      use Ryker.PollingWorker, lane: :work, interval: :poll_interval_ms

  The worker keeps its own `start_link/1`, so its name and supervision stay its
  own, and implements `c:poll/1`: one cycle, returning the milliseconds until
  the next. `c:setup/1` turns the start argument into the process state or
  refuses to start; a worker without one keeps the argument as its state.
  `:lane` names the worker in the backoff warning, and `:interval` is the state
  key holding the configured interval, which a backoff never undercuts.
  """

  require Logger

  @minimum_database_retry_ms 1_000

  @callback setup(argument :: term()) :: {:ok, state :: map()} | {:stop, reason :: term()}
  @callback poll(state :: map()) :: non_neg_integer()
  @optional_callbacks setup: 1

  defmacro __using__(options) do
    lane = Keyword.fetch!(options, :lane)
    interval = Keyword.fetch!(options, :interval)

    quote do
      use GenServer

      @behaviour Ryker.PollingWorker

      @impl GenServer
      def init(argument), do: Ryker.PollingWorker.init(__MODULE__, argument)

      @impl GenServer
      def handle_info(:poll, state),
        do: Ryker.PollingWorker.handle_poll(__MODULE__, unquote(lane), unquote(interval), state)
    end
  end

  @doc "Asks a polling worker to poll now instead of at its next timer."
  @spec poll_now(pid() | atom()) :: :ok
  def poll_now(worker) do
    send(worker, :poll)
    :ok
  end

  @doc false
  def init(module, argument) do
    result =
      if function_exported?(module, :setup, 1), do: module.setup(argument), else: {:ok, argument}

    with {:ok, _state} <- result do
      send(self(), :poll)
      result
    end
  end

  @doc false
  def handle_poll(module, lane, interval, state) do
    delay = run(lane, Map.fetch!(state, interval), fn -> module.poll(state) end)
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  @doc """
  Runs one cycle and returns its delay, or the backoff when the database refused it.
  """
  @spec run(atom(), pos_integer(), (-> non_neg_integer())) :: non_neg_integer()
  def run(lane, interval_ms, cycle) do
    cycle.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      # Restarting every poller during a shared pool outage spends the supervisor
      # restart budget. Retry only on the next timer; durable claims still own work.
      # A statement the database refused is the same outage seen one step later;
      # its code names the refusal without the statement or its parameters.
      delay = max(interval_ms, @minimum_database_retry_ms)

      Logger.warning(
        "database polling unavailable; retrying after backoff (#{lane}, #{delay} ms#{refusal(error)})"
      )

      delay
  end

  defp refusal(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code) and not is_nil(code),
    do: ", #{code}"

  defp refusal(_error), do: ""
end
