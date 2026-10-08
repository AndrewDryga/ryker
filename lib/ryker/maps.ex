defmodule Ryker.Maps do
  @moduledoc """
  Small helpers for building a map or a keyword list, shared across contexts
  (Emisar keeps the same one as `Emisar.Maps`).
  """

  @doc """
  `collection` with `key` set to `value` when there is a value; unchanged for
  nil. Works on a map and on a keyword list.
  """
  @spec put_present(map() | keyword(), term(), term()) :: map() | keyword()
  def put_present(collection, _key, nil), do: collection
  def put_present(map, key, value) when is_map(map), do: Map.put(map, key, value)
  def put_present(list, key, value) when is_list(list), do: Keyword.put(list, key, value)
end
