defmodule Ryker.State.MemorySearchPage do
  @moduledoc false
  import Ecto.Query
  alias Ryker.{CanonicalJSON, Repo}

  # A cursor traverses content order, never retrieval counters. Rows changed
  # after the cutoff disappear from this traversal; a new search sees them.
  def first(query, scope) do
    # Operator edits use the database clock. Comparing them with the host clock
    # intermittently hides an edit from a search immediately after confirmation.
    cutoff = Repo.now!()

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
    excluded_ids = Map.get(page, :excluded_ids, [])

    query =
      from(item in query,
        where: item.inserted_at <= ^page.cutoff,
        where: item.id not in ^excluded_ids,
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

  # These selectors are host-resolved lookup sources, not a replacement caller
  # scope. Each owner still applies its normal visibility and source fences.
  def related_sources(query, %{source_targets: targets}) do
    from(item in query,
      where:
        fragment(
          """
          EXISTS (
            SELECT 1 FROM ryker_learning_roots(?) r
            JOIN conversation_observations o ON o.id = CASE
              WHEN pg_input_is_valid(r->>'observation_id', 'uuid')
              THEN (r->>'observation_id')::uuid ELSE NULL END
          JOIN jsonb_to_recordset(?::text::jsonb) AS target(conversation_ref text, thread_ref text, message_ref text)
              ON target.conversation_ref = o.conversation_ref
             AND ((target.thread_ref IS NOT NULL AND target.thread_ref = o.thread_ref)
                  OR (target.message_ref IS NOT NULL AND target.message_ref = o.source_message_ref))
          )
          """,
          item.source_dependencies,
          ^CanonicalJSON.encode!(targets)
        )
    )
  end

  def related_sources(query, _page), do: query

  def related_originals(query, %{source_targets: targets}, conversation, thread, message) do
    selected =
      Enum.reduce(targets, dynamic(false), fn target, selected ->
        source_conversation = target["conversation_ref"]
        source_thread = target["thread_ref"]
        source_message = target["message_ref"]
        identity = dynamic([item], false)

        identity =
          if source_thread,
            do: dynamic([item], ^identity or ^thread == ^source_thread),
            else: identity

        identity =
          if source_message,
            do: dynamic([item], ^identity or ^message == ^source_message),
            else: identity

        dynamic([item], ^selected or (^conversation == ^source_conversation and ^identity))
      end)

    from(item in query, where: ^selected)
  end

  def related_originals(query, _page, _conversation, _thread, _message), do: query

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
