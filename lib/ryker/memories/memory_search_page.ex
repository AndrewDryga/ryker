defmodule Ryker.Memories.MemorySearchPage do
  @moduledoc false
  alias Ryker.Memories.SearchPage
  alias Ryker.Repo

  # How far ahead of the database clock a row's own stamp may be and still
  # count as written before the search began.
  @clock_skew_seconds 5

  # A cursor traverses content order, never retrieval counters. Rows changed
  # after the cutoff disappear from this traversal; a new search sees them.
  def first(query, scope) do
    # Rows carry both clocks: operator edits the database's, and summaries and
    # other rows Ecto stamps the host's. A cutoff on the host clock hid an edit
    # from a search right after confirmation; one exactly on the database
    # clock hid a summary written just before the search whenever the
    # database clock ran behind the host's (four continuity recall tests on
    # busy gate runs, 2026-09-26). The cutoff allows for that skew; only the
    # first page uses it, and later pages follow the cursor.
    cutoff = DateTime.add(Repo.now!(), @clock_skew_seconds, :second)

    %{
      query: String.trim(query),
      scope: scope,
      cutoff: cutoff,
      position: nil,
      time_basis: "changed",
      after: nil,
      before: nil
    }
  end

  @doc """
  The next row of `query` that `page` reaches, with the cursor after it, or
  `:done` (`Ryker.Memories.SearchPage.Query.next/5`).
  """
  def one(query, page, text, changed, source) do
    case Repo.fetch(SearchPage.Query.next(query, page, text, changed, source)) do
      {:error, :not_found} -> :done
      {:ok, %{item: item, time: time}} -> {:ok, item, [DateTime.to_iso8601(time), item.id]}
    end
  end
end
