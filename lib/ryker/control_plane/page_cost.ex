defmodule Ryker.ControlPlane.PageCost do
  @moduledoc """
  What reading a console page costs: the database queries it ran and how long
  it took, counted in the page's own process (Andrew, 2026-10-04: "measure how
  many requests each page takes").

  A telemetry handler attached at start (`attach/0`) counts each query in a
  process that asked for it (`measure/2`), and nowhere else. A read that is
  slow or runs many queries is logged, so a page that becomes expensive says
  so in the log the day it does.
  """
  require Logger

  @key {__MODULE__, :cost}
  @event [:ryker, :repo, :query]
  # A timeline runs about 150 cheap queries; twice that is a page gone wrong.
  @slow_ms 500
  @many_queries 300

  @doc "Counts each query of a process that measures; attached once, at start."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach, do: :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_query/4, nil)

  @doc false
  def handle_query(_event, measurements, _metadata, _config) do
    case Process.get(@key) do
      {queries, native} ->
        # A page read's query count, kept where the telemetry handler runs: bookkeeping, not who acts.
        # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
        Process.put(@key, {queries + 1, native + Map.get(measurements, :total_time, 0)})

      nil ->
        :ok
    end
  end

  @doc """
  Runs `fun`, counting the queries it runs in this process, and logs what it
  cost when it was slow or ran many queries. Returns what `fun` returns.

  The page at `path` is logged by its kind: the path's words stay and every id
  in it becomes `:id`. The full path put Slack workspace and channel ids and
  request ids in the log (2026-10-04 review).
  """
  @spec measure(String.t(), boolean(), (-> result)) :: result when result: term()
  def measure(path, connected?, fun) do
    label = "#{route(path)} (#{if connected?, do: "live", else: "first render"})"
    # The count starts with the read and is restored after it; nothing here says who acts.
    # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
    previous = Process.put(@key, {0, 0})
    started = System.monotonic_time()

    try do
      fun.()
    after
      {queries, native} = Process.get(@key)
      restore(previous)
      ms = System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
      db_ms = System.convert_time_unit(native, :native, :millisecond)
      log(label, queries, db_ms, ms)
    end
  end

  defp route(path) do
    segments =
      for segment <- String.split(path, "/", trim: true),
          do: if(Regex.match?(~r/\A[a-z]+(?:-[a-z]+)*\z/, segment), do: segment, else: ":id")

    "/" <> Enum.join(segments, "/")
  end

  defp restore(nil), do: Process.delete(@key)
  # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
  defp restore(previous), do: Process.put(@key, previous)

  defp log(label, queries, db_ms, ms) when ms >= @slow_ms or queries >= @many_queries do
    Logger.warning(
      "Slow page #{label}: #{ms} ms, #{queries} queries, #{db_ms} ms in the database"
    )
  end

  defp log(label, queries, db_ms, ms),
    do: Logger.debug("Page #{label}: #{ms} ms, #{queries} queries, #{db_ms} ms in the database")
end
