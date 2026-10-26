defmodule Ryker.Flywheel.Coverage do
  @moduledoc "Per-source contiguous coverage; an outage never moves another source's cursor backwards."
  alias Ryker.Flywheel.{Protocol, Run}

  def plan(runs, sources, starts_at, ends_at, since_last) do
    Map.new(sources, fn source ->
      start = if since_last, do: next_start(runs, source, starts_at), else: starts_at
      # Re-read a day for sources without a change feed; receipts skip unchanged versions.
      overlap = if since_last, do: DateTime.add(start, -1, :day), else: start
      overlap = Enum.max([overlap, starts_at], DateTime)

      {source,
       %{
         "from" => DateTime.to_iso8601(overlap),
         "until" => DateTime.to_iso8601(ends_at),
         "status" => "pending",
         "cursor" => nil,
         "reviewed" => 0,
         "pending" => nil
       }}
    end)
  end

  defp next_start(runs, source, starts_at) do
    runs
    |> Enum.flat_map(&interval(&1, source))
    |> Enum.sort_by(&elem(&1, 0), DateTime)
    |> Enum.reduce(starts_at, fn {first, last}, covered ->
      if DateTime.compare(first, covered) != :gt and DateTime.compare(last, covered) == :gt,
        do: last,
        else: covered
    end)
  end

  defp interval(%Run{progress: progress}, source) do
    case progress[source] do
      %{"status" => "complete", "from" => first, "until" => last} ->
        {:ok, first} = Protocol.datetime(first)
        {:ok, last} = Protocol.datetime(last)
        [{first, last}]

      %{"status" => "expired", "closed" => true, "from" => first, "until" => last} ->
        # This advances the processing schedule, never the claim of complete coverage.
        # The original expired interval and its reason remain in the run ledger.
        [{Protocol.datetime!(first), Protocol.datetime!(last)}]

      _missing_or_incomplete ->
        []
    end
  end
end
