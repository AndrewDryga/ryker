defmodule Ryker.Fixtures.MemoryPages do
  @moduledoc """
  Memory search as the memory search tool reads it, one kind at a time.

  Production reads each kind through its `search_page/2`, a page at a time,
  inside one transaction (`Ryker.State.MemorySearch`). Tests that ask what a
  search finds for one kind page through the same functions, so the product
  keeps no second search path that only tests call.
  """

  alias Ryker.Repo
  alias Ryker.State.{Behaviors, MemorySearchPage}
  alias Ryker.State.Memories.Recall

  def guidance(context, query, scope, limit \\ 20),
    do: read(&Behaviors.search_page(context, &1), query, scope, limit)

  def facts(context, query, scope, limit \\ 20),
    do: read(&Recall.search_page(context, &1), query, scope, limit)

  defp read(fetch, query, scope, limit) do
    {:ok, documents} =
      Repo.transaction(fn ->
        MemorySearchPage.read(MemorySearchPage.first(query, scope), limit, fetch)
      end)

    documents
  end
end
