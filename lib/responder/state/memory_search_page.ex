defmodule Responder.State.MemorySearchPage do
  @moduledoc false
  import Ecto.Query
  alias Responder.Repo

  # A cursor traverses content order, never retrieval counters. Rows changed
  # after the cutoff disappear from this traversal; a new search sees them.
  def first(query, scope) do
    # Operator edits use the database clock. Comparing them with the host clock
    # intermittently hides an edit from a search immediately after confirmation.
    %{rows: [[cutoff]]} = Repo.query!("SELECT clock_timestamp()")

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

  def one(query, page, text, changed, source) do
    search = page.query

    query =
      from(item in query,
        where: item.inserted_at <= ^page.cutoff,
        where: ^dynamic([item], ^changed <= ^page.cutoff),
        where:
          ^dynamic(
            [item],
            fragment(
              "position(lower(?) in lower(?)) > 0 OR to_tsvector('simple', ?) @@ plainto_tsquery('simple', ?)",
              ^search,
              ^text,
              ^text,
              ^search
            )
          )
      )

    date = if page.time_basis == "source", do: source, else: changed
    query = date_filter(query, page, date)

    query =
      case page.position do
        nil ->
          query

        [time, id] ->
          {:ok, time, 0} = DateTime.from_iso8601(time)

          from(item in query,
            where: ^dynamic([item], ^changed < ^time or (^changed == ^time and item.id < ^id))
          )
      end

    selected = %{item: dynamic([item], item), time: changed}

    query =
      from(item in query,
        order_by: ^[desc: changed, desc: dynamic([item], item.id)],
        limit: 1,
        select: ^selected
      )

    case Repo.one(query) do
      nil -> :done
      %{item: item, time: time} -> {:ok, item, [DateTime.to_iso8601(time), item.id]}
    end
  end

  defp date_filter(query, %{after: nil, before: nil}, _date), do: query
  defp date_filter(query, _page, nil), do: from(item in query, where: false)

  defp date_filter(query, page, date) do
    query =
      if page.after,
        do: from(item in query, where: ^dynamic([item], ^date >= ^page.after)),
        else: query

    if page.before,
      do: from(item in query, where: ^dynamic([item], ^date < ^page.before)),
      else: query
  end

  def read(page, count, fetch), do: collect(page, count, fetch, [], 0)
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
