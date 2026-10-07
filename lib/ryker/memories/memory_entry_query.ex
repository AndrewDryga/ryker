defmodule Ryker.Memories.MemoryEntryQuery do
  @moduledoc "Facts people confirmed, for every read of `operational_memory_entries`."
  import Ecto.Query
  alias Ryker.Memories.MemoryEntry

  def all, do: from(entries in MemoryEntry, as: :operational_memory_entries)

  def active(queryable \\ all()),
    do: where(queryable, [operational_memory_entries: m], m.status == :active)

  def confirmed_between(queryable, from, to) do
    where(
      queryable,
      [operational_memory_entries: m],
      m.confirmed_at >= ^from and m.confirmed_at < ^to
    )
  end
end
