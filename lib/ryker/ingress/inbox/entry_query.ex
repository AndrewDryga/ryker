defmodule Ryker.Ingress.Inbox.EntryQuery do
  @moduledoc "Recorded messages and events, for every read of `ingress_inbox_entries`."
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry

  def all, do: from(entries in Entry, as: :ingress_inbox_entries)

  def by_source_event(queryable \\ all(), source_kind, event_ref) do
    where(
      queryable,
      [ingress_inbox_entries: e],
      e.source_kind == ^source_kind and e.event_ref == ^event_ref
    )
  end

  def newest_first(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], desc: e.inserted_at)

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
