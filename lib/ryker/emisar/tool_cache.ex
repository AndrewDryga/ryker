defmodule Ryker.Emisar.ToolCache do
  @moduledoc """
  Holds each Emisar connection's tool catalog between reads
  (`Ryker.Emisar.Tools`).

  An entry is keyed by the connection, its address and its key's fingerprint,
  so a replaced key or address is a different entry. It is kept for as long as
  its reader asked; a lookup past that is a miss. Reads never wait on this
  process: it only owns the table, and a table that is not there is a miss.
  """

  use GenServer

  @table __MODULE__
  @maximum_entries 256

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] ->
        if expires_at > now(), do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(term(), term(), pos_integer()) :: :ok
  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    # Keys only change when a key or address does, so the table stays small;
    # the bound is for a key replaced over and over.
    if :ets.info(@table, :size) >= @maximum_entries, do: :ets.delete_all_objects(@table)
    :ets.insert(@table, {key, value, now() + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_options) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
