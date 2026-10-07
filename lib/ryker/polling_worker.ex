defmodule Ryker.PollingWorker do
  @moduledoc """
  The one loop every timer-driven poller runs.

  A polling worker polls once as soon as it starts, then again after the delay
  its last cycle returned: nothing when more work is waiting, and when it went
  idle, until its next row falls due. A database outage inside a cycle waits
  for the next poll instead of restarting the process.

      use Ryker.PollingWorker, lane: :work, interval: :poll_interval_ms

  The worker keeps its own `start_link/1`, so its name and supervision stay its
  own, and implements `c:poll/1`: one cycle, returning the milliseconds until
  the next, or those and the state the next cycle starts from, when a cycle
  learns something the next must know. `c:setup/1` turns the start argument
  into the process state or refuses to start; a worker without one keeps the
  argument as its state.
  `:lane` names the worker in the backoff warning, and `:interval` is the state
  key holding the configured interval, which a backoff never undercuts.

  A worker whose rows another part of Ryker writes names the announcements of
  those writes in `c:wake_on/1`: the owning contexts' own `subscribe_*`
  functions (`Ryker.PubSub`). Every message they bring asks for a poll now; a
  burst of them, and all that arrive while a cycle runs, make one more poll.
  A steady stream never makes a worker poll more than four times a second,
  the fastest any worker polled on its timer before it slept: the first few
  are answered at once, the rest a moment later. An idle install then polls
  only when a row falls due by the clock, which `idle_delay/2` sleeps until,
  and on a long safety-net interval for anything no announcement names.

  A worker whose rows fall due by the clock alone, though an announcement says
  one changed, reads each announcement in `c:woken/2` first and makes what it
  names due, so the poll it brings finds it.
  """

  require Logger

  @minimum_database_retry_ms 1_000
  @timer {__MODULE__, :timer}
  @woken {__MODULE__, :woken}
  @wakes {__MODULE__, :wakes}
  @wake_credit {__MODULE__, :wake_credit}

  # Polls on announcements are paced by a bucket of four, refilled one every
  # 250 ms: a burst is answered at once, a stream no faster than the old
  # fastest timer.
  @wake_burst 4
  @wake_refill_ms 250

  # An idle worker that wakes on announcements polls at least this often, to
  # catch a change nothing announced. Every row that falls due by time is
  # slept until exactly (`idle_delay/2`), so this is only a safety net.
  @idle_interval_ms 10_000

  # How far back `idle_delay/2` asks for rows falling due, and how soon it
  # polls again for one that is due already; see its doc.
  @lookback_ms 1_000
  @due_retry_ms 250

  @callback setup(argument :: term()) :: {:ok, state :: map()} | {:stop, reason :: term()}
  @callback poll(state :: map()) :: non_neg_integer() | {non_neg_integer(), map()}

  @doc """
  The announcements that wake this worker: functions that each subscribe the
  calling process to one context's topic, such as
  `&Ryker.Ingress.Inbox.subscribe_inputs/0`.
  """
  @callback wake_on(state :: map()) :: [(-> :ok | {:error, term()})]

  @doc """
  Reads one announcement before the poll it asks for, to make the rows it
  names due. A database that refuses is the poll's to back off from; the row
  then waits for its clock.
  """
  @callback woken(message :: term(), state :: map()) :: :ok
  @optional_callbacks setup: 1, wake_on: 1, woken: 2

  defmacro __using__(options) do
    lane = Keyword.fetch!(options, :lane)
    interval = Keyword.fetch!(options, :interval)

    quote do
      use GenServer

      @behaviour Ryker.PollingWorker

      @impl GenServer
      def init(argument), do: Ryker.PollingWorker.init(__MODULE__, argument)

      @impl GenServer
      def handle_info(message, state) do
        Ryker.PollingWorker.handle_info(
          __MODULE__,
          unquote(lane),
          unquote(interval),
          message,
          state
        )
      end
    end
  end

  @doc """
  Asks a polling worker to poll now instead of at its next timer.

  The early poll replaces the timer that was waiting, so asking again and
  again never leaves more than one poll pending.
  """
  @spec poll_now(pid() | atom()) :: :ok
  def poll_now(worker) do
    send(worker, :poll)
    :ok
  end

  @doc """
  The safety-net interval of a worker that wakes on announcements: how long it
  sleeps when nothing woke it and nothing falls due sooner.
  """
  @spec idle_interval_ms() :: pos_integer()
  def idle_interval_ms, do: @idle_interval_ms

  @doc """
  How long a worker that found nothing to do sleeps: until the earliest row
  `next_due_at` names falls due, and never longer than `idle_ms`.

  `next_due_at` is given a moment a second ago and answers the earliest time
  after it at which a row of the worker's queue becomes claimable by the clock
  alone (a retry's backoff ending, a lease running out, a timer), or nil. A
  row that fell due between the cycle's claim and this read, or by a database
  clock a little behind this one, is due already, so the worker polls again
  after #{@due_retry_ms} ms, the fastest any worker polled before it slept; one
  that is due but still cannot be claimed, waiting behind another, stops
  counting a second later.
  """
  @spec idle_delay((DateTime.t() -> DateTime.t() | nil), pos_integer()) :: non_neg_integer()
  def idle_delay(next_due_at, idle_ms) when is_function(next_due_at, 1) do
    now = DateTime.utc_now()

    case next_due_at.(DateTime.add(now, -@lookback_ms, :millisecond)) do
      nil ->
        idle_ms

      # A computed due time (a min, a greatest, an interval sum) comes back
      # from the database without a zone; Ryker keeps every time in UTC.
      %NaiveDateTime{} = due_at ->
        idle_delay(fn _since -> DateTime.from_naive!(due_at, "Etc/UTC") end, idle_ms)

      %DateTime{} = due_at ->
        case DateTime.diff(due_at, now, :microsecond) do
          wait when wait > 0 -> min(div(wait + 999, 1_000), idle_ms)
          _due -> min(@due_retry_ms, idle_ms)
        end
    end
  end

  @doc false
  def init(module, argument) do
    result =
      if function_exported?(module, :setup, 1), do: module.setup(argument), else: {:ok, argument}

    with {:ok, state} <- result do
      subscribe(module, state)
      send(self(), :poll)
      result
    end
  end

  # Subscribed before the first poll: anything committed before then, that
  # poll reads, and anything committed after, its announcement wakes.
  defp subscribe(module, state) do
    if function_exported?(module, :wake_on, 1) do
      subscriptions = module.wake_on(state)
      Enum.each(subscriptions, fn subscribe -> :ok = subscribe.() end)
      # The poll machinery keeps its own bookkeeping (wake subscriptions, the
      # woken flag, wake credit, the pending timer) in the worker's process, beside
      # the state its module owns; none of it says who acts.
      # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
      Process.put(@wakes, subscriptions != [])
    end
  end

  @doc false
  def handle_info(module, lane, interval, :poll, state) do
    # A wake that arrives from here on may name a row this cycle's reads miss,
    # so it asks for the poll after this one.
    Process.delete(@woken)

    {delay, state} =
      case run(lane, Map.fetch!(state, interval), fn -> module.poll(state) end) do
        {delay, %{} = next} -> {delay, next}
        delay -> {delay, state}
      end

    schedule_poll(delay)
    {:noreply, state}
  end

  def handle_info(module, lane, _interval, message, state) do
    if Process.get(@wakes) do
      woken(module, lane, message, state)
      wake()
    else
      Logger.error("#{inspect(module)} received an unexpected message: #{inspect(message)}")
    end

    {:noreply, state}
  end

  defp woken(module, lane, message, state) do
    if function_exported?(module, :woken, 2), do: :ok = module.woken(message, state)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.warning("database unavailable to read a wake (#{lane}#{refusal(error)})")
  end

  # One poll per burst: every announcement already queued, and every one
  # heard while that poll waits its turn, is answered by the same poll, which
  # starts after each of them was received and so reads what they announced.
  defp wake do
    unless Process.get(@woken) do
      # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
      Process.put(@woken, true)

      case wake_wait() do
        0 -> send(self(), :poll)
        wait -> poll_within(wait)
      end
    end
  end

  # The bucket, kept as milliseconds of credit: each wake spends one refill
  # period, and a wake that finds too little waits until it would have been
  # refilled.
  defp wake_wait do
    now = System.monotonic_time(:millisecond)
    full = @wake_burst * @wake_refill_ms
    {credit, at} = Process.get(@wake_credit, {full, now})
    credit = min(credit + now - at, full) - @wake_refill_ms
    # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
    Process.put(@wake_credit, {credit, now})
    max(-credit, 0)
  end

  # A timer that fires sooner, or has fired already, answers the wake itself.
  defp poll_within(wait) do
    case Process.get(@timer) && Process.read_timer(Process.get(@timer)) do
      remaining when is_integer(remaining) and remaining <= wait -> :ok
      false -> :ok
      _later_or_none -> schedule_poll(wait)
    end
  end

  # One pending poll at a time. A poll asked for early used to arm its own
  # timer beside the one already waiting, and each such loop ran forever.
  defp schedule_poll(delay) do
    # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
    case Process.put(@timer, Process.send_after(self(), :poll, delay)) do
      nil -> :ok
      waiting -> Process.cancel_timer(waiting, async: true, info: false)
    end
  end

  @doc """
  Runs one cycle and returns what it returned, or the backoff when the
  database refused it.
  """
  @spec run(atom(), pos_integer(), (-> delay)) :: delay
        when delay: non_neg_integer() | {non_neg_integer(), map()}
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
