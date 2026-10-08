defmodule Ryker.Maps do
  @moduledoc """
  Small helpers for building and checking a map or a keyword list, shared
  across contexts (Emisar keeps the same one as `Emisar.Maps`).
  """

  @doc """
  Whether `value` is a map with exactly `keys`, in any order, and with any of
  `optional` besides. A document decoded from a model, a worker or a vendor is
  refused when it carries a key nobody reads, rather than read around it.
  """
  @spec exact_keys?(term(), [term()], [term()]) :: boolean()
  def exact_keys?(value, keys, optional \\ [])

  def exact_keys?(map, keys, optional) when is_map(map) do
    present = Map.keys(map) -- optional
    Enum.sort(present) == Enum.sort(keys)
  end

  def exact_keys?(_value, _keys, _optional), do: false

  @doc "Whether `value` is a map with no key outside `allowed`."
  @spec only_keys?(term(), [term()]) :: boolean()
  def only_keys?(map, allowed) when is_map(map), do: Map.keys(map) -- allowed == []
  def only_keys?(_value, _allowed), do: false

  @doc """
  `collection` with `key` set to `value` when there is a value; unchanged for
  nil. Works on a map and on a keyword list.
  """
  @spec put_present(map() | keyword(), term(), term()) :: map() | keyword()
  def put_present(collection, _key, nil), do: collection
  def put_present(map, key, value) when is_map(map), do: Map.put(map, key, value)
  def put_present(list, key, value) when is_list(list), do: Keyword.put(list, key, value)
end
