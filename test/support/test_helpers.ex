defmodule Ryker.TestHelpers do
  @moduledoc """
  Helpers that test suites each used to define for themselves (codebase
  wave 4): 31 copies of the SHA-256 digest and 6 of `eventually`, with waits
  from half a second to two. By 2026-10-04 nine digests and three pollers had
  been copied again.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  alias Ryker.Crypto
  alias Ryker.Evals.Job
  alias Ryker.Observability.Progress
  alias Ryker.Repo

  @doc "`Ryker.Crypto.sha256_hex/1`, by the short name ninety suites use for it."
  @spec digest(iodata()) :: String.t()
  def digest(value), do: Crypto.sha256_hex(value)

  @doc """
  Whether `check` becomes true within `within_ms`, polling every 10 ms.

  For state another process changes on its own time; a message is better
  awaited with `assert_receive`. `refute eventually(check, ms)` holds that
  something does not happen for `ms`, checking throughout rather than once
  after a sleep.
  """
  @spec eventually((-> as_boolean(term())), pos_integer()) :: boolean()
  def eventually(check, within_ms \\ 2_000) when is_function(check, 0) do
    poll(check, System.monotonic_time(:millisecond) + within_ms)
  end

  @doc """
  Waits until each of `clocks` (`:host`, `:database`) reads past `moment`, for
  a test that stamps a row a moment ahead of now. PostgreSQL keeps its own
  clock, a few milliseconds off the host's and, after the Mac restarted on
  2026-10-03, a quarter of a second ahead. Three suites kept their own wait.
  """
  @spec clocks_past!(DateTime.t(), [:host | :database]) :: :ok
  def clocks_past!(moment, clocks \\ [:host, :database]) do
    if eventually(fn -> Enum.all?(clocks, &DateTime.after?(clock(&1), moment)) end, 5_000),
      do: :ok,
      else: flunk("the clocks never passed #{moment}")
  end

  @doc """
  Whether the operating-system process `os_pid` is gone within `within_ms`. A
  killed program may be reaped a moment after it dies. Two suites kept a copy.
  """
  @spec os_process_gone?(String.t(), pos_integer()) :: boolean()
  def os_process_gone?(os_pid, within_ms \\ 1_000) do
    eventually(
      fn ->
        elem(System.cmd("sh", ["-c", "kill -0 \"$1\" 2>/dev/null", "sh", os_pid]), 1) != 0
      end,
      within_ms
    )
  end

  @doc """
  `worker` once it has handled every message sent to it so far, the first poll
  a polling worker sends itself as it starts among them. Tests that slept and
  then checked the worker was alive passed before that poll had run
  (2026-10-04 review).
  """
  @spec settled(GenServer.server()) :: GenServer.server()
  def settled(worker) do
    _state = :sys.get_state(worker)
    worker
  end

  @doc """
  Unsets the eval socket and target variables for the calling test and puts
  them back after it. Tests that expect an eval to stop for want of them broke
  wherever they were exported, as the eval docs ask (2026-10-04 review).
  """
  @spec without_eval_targets() :: :ok
  def without_eval_targets do
    exported =
      for name <- Job.variables(), value = System.get_env(name), do: {name, value}

    Enum.each(exported, fn {name, _value} -> System.delete_env(name) end)
    ExUnit.Callbacks.on_exit(fn -> System.put_env(exported) end)
  end

  @doc "How many beats `lane` has recorded (`Ryker.Observability.Progress`); 0 before its first."
  @spec beats(atom()) :: non_neg_integer()
  def beats(lane) do
    {:ok, lanes} = Progress.snapshot(DateTime.utc_now())
    Enum.find_value(lanes, 0, &(&1.lane == lane && &1.cycle_count))
  end

  @doc """
  The page's outline: each node `selector` matches in `document`, as its tag and
  first class (`section.kit-card`), in order. Five page tests kept a copy.
  """
  @spec outline(LazyHTML.t(), String.t()) :: [String.t()]
  def outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end

  defp clock(:host), do: DateTime.utc_now()
  defp clock(:database), do: Repo.now!()

  defp poll(check, deadline) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        # The one wait the suites share: what it watches changes in another
        # process, which sends no message to await.
        # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
        Process.sleep(10)
        poll(check, deadline)
    end
  end
end
