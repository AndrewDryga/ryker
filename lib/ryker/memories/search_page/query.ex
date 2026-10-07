defmodule Ryker.Memories.SearchPage.Query do
  @moduledoc """
  One page of a memory search, over whichever kind of memory a query reads:
  the next row a cursor reaches, matching the words searched for, and
  related to the messages a search names. Each memory's Query module says
  which of its fields a page reads (its text, when it changed, its source).
  """
  import Ecto.Query
  alias Ryker.CanonicalJSON

  @doc """
  The next row of `queryable` that `page` reaches: written before the search
  began, not excluded, matching `page.query` in `text`, within the page's
  dates and before its cursor, newest `changed` first.
  """
  def next(queryable, page, text, changed, source) do
    search = page.query
    excluded_ids = Map.get(page, :excluded_ids, [])

    query =
      from(item in queryable,
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

    from(item in query,
      order_by: ^[desc: changed, desc: dynamic([item], item.id)],
      limit: 1,
      select: ^selected
    )
  end

  @doc """
  Rows whose sources include a message the page names. These selectors are
  host-resolved lookup sources, not a replacement caller scope: each owner
  still applies its normal visibility and source fences.
  """
  def related_sources(queryable, %{source_targets: targets}) do
    from(item in queryable,
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

  def related_sources(queryable, _page), do: queryable

  @doc "Rows said in a message or thread the page names, by the row's own `conversation`, `thread` and `message` fields."
  def related_originals(queryable, %{source_targets: targets}, conversation, thread, message) do
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

    from(item in queryable, where: ^selected)
  end

  def related_originals(queryable, _page, _conversation, _thread, _message), do: queryable

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
end
