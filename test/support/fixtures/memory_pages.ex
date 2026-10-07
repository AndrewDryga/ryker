defmodule Ryker.Fixtures.MemoryPages do
  @moduledoc """
  Memory search as the memory search tool reads it, one kind at a time.

  Production reads each kind through its `search_page/2`, a page at a time,
  inside one transaction (`Ryker.Memories.MemorySearch`). Tests that ask what a
  search finds for one kind page through the same functions, so the product
  keeps no second search path that only tests call.
  """

  alias Ryker.Behaviors.Recall, as: BehaviorRecall
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Memories.Recall
  alias Ryker.Repo

  def guidance(context, query, scope, limit \\ 20),
    do: search(&BehaviorRecall.search_page(context, &1), query, scope, limit)

  def facts(context, query, scope, limit \\ 20),
    do: search(&Recall.search_page(context, &1), query, scope, limit)

  @doc """
  Up to `count` documents `fetch` returns from `page` on, following its
  cursor, with the 64 skipped rows a search visits at most.
  """
  def read(page, count, fetch), do: collect(page, count, fetch, [], 0)

  defp search(fetch, query, scope, limit) do
    {:ok, documents} =
      Repo.transaction(fn -> read(MemorySearchPage.first(query, scope), limit, fetch) end)

    documents
  end

  defp collect(_page, 0, _fetch, entries, _skips), do: Enum.reverse(entries)
  defp collect(_page, _count, _fetch, entries, 64), do: Enum.reverse(entries)

  defp collect(page, count, fetch, entries, skips) do
    case fetch.(page) do
      {:ok, document, position} ->
        collect(%{page | position: position}, count - 1, fetch, [document | entries], skips)

      {:skip, position} ->
        collect(%{page | position: position}, count, fetch, entries, skips + 1)

      :done ->
        Enum.reverse(entries)
    end
  end
end
